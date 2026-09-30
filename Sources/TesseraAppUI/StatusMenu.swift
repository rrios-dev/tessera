import AppKit
import TesseraConfig
import TesseraCore
import TesseraEngine
import TesseraPorts

/// The menu bar item (audit E1). The title shows the macOS desktop and, in emulated mode, the
/// group; the menu is built when it opens, from the latest state, so its counts are never stale.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    var onAction: (@MainActor (UIAction) -> Void)?
    private var state = UIState()
    private var actions: [UIAction] = []

    override init() {
        super.init()
        menu.delegate = self
        item.menu = menu
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        item.button?.imagePosition = .imageLeading
        item.button?.setAccessibilityLabel("Tessera")
        render()
    }

    func update(_ state: UIState) {
        self.state = state
        render()
    }

    private func render() {
        guard let button = item.button else { return }
        let image: NSImage?
        let title: String
        switch state.status {
        case .active, .starting:
            image = BrandMark.image()
            if let desktop = state.desktopNumber {
                let group = state.nativeWorkspaces || state.groups.count <= 1 ? "" : " · " + (state.groups.first { $0.isActive }?.name ?? "")
                title = "\(desktop)\(group)"
            } else {
                title = "—"
            }
        case .paused: image = BrandMark.image(outlined: true); title = ""
        case .noPermission: image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Tessera"); title = ""
        case .safeMode: image = NSImage(systemSymbolName: "lifepreserver", accessibilityDescription: "Tessera"); title = ""
        }
        button.image = image
        button.image?.isTemplate = true
        button.title = title.isEmpty ? "" : " \(title)"
        button.setAccessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        switch state.status {
        case .active, .starting:
            guard let desktop = state.desktopNumber else { return L10n.t("Pantalla completa de macOS", "macOS full screen") }
            return L10n.t("Escritorio \(desktop)", "Desktop \(desktop)")
        case .paused: return L10n.t("En pausa", "Paused")
        case .noPermission: return L10n.t("Sin permiso de Accesibilidad", "No Accessibility permission")
        case .safeMode: return L10n.t("Modo seguro", "Safe mode")
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        actions.removeAll()
        buildStatusSection(menu)
        if state.status.isActive {
            buildDesktopSection(menu)
            menu.addItem(.separator())
            buildLayoutSection(menu)
        }
        menu.addItem(.separator())
        buildControlSection(menu)
        buildActivity(menu)
        menu.addItem(.separator())
        let keys = NSMenuItem(title: L10n.t("Atajos de teclado…", "Keyboard shortcuts…"), action: #selector(showKeys(_:)), keyEquivalent: "")
        keys.target = self
        menu.addItem(keys)
        let quit = NSMenuItem(title: L10n.t("Salir de Tessera y restaurar ventanas", "Quit Tessera and restore windows"),
                              action: #selector(run(_:)), keyEquivalent: "q")
        quit.target = self
        quit.tag = register(.quit)
        menu.addItem(quit)
    }

    private func buildStatusSection(_ menu: NSMenu) {
        switch state.status {
        case .paused(.user):
            menu.addItem(disabled(L10n.t("Tessera en pausa", "Tessera is paused")))
        case .paused(.stageManager):
            menu.addItem(disabled(L10n.t("En pausa: Stage Manager está activo", "Paused: Stage Manager is on")))
        case .paused(.conflict(let names)):
            menu.addItem(disabled(L10n.t("En pausa: \(names.joined(separator: ", ")) está ordenando ventanas", "Paused: \(names.joined(separator: ", ")) is tiling windows")))
            for name in names where name == "AeroSpace" || name == "Amethyst" {
                let item = NSMenuItem(title: L10n.t("Salir de \(name)", "Quit \(name)"), action: #selector(quitTiler(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                menu.addItem(item)
            }
        case .noPermission:
            menu.addItem(disabled(L10n.t("Sin permiso de Accesibilidad", "No Accessibility permission")))
            let open = NSMenuItem(title: L10n.t("Abrir Privacidad › Accesibilidad…", "Open Privacy › Accessibility…"), action: #selector(openAccessibility(_:)), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
        case .safeMode:
            menu.addItem(disabled(L10n.t("Modo seguro: ventanas restauradas, sin mosaico", "Safe mode: windows restored, no tiling")))
            menu.addItem(action(L10n.t("Reintentar", "Retry"), .retry))
        case .active, .starting:
            if state.screensBeyondPrimary > 0 {
                menu.addItem(disabled(L10n.t("Solo se ordena la pantalla principal", "Only the main screen is tiled")))
            }
        }
    }

    private func buildDesktopSection(_ menu: NSMenu) {
        let base = state.keymap.first { $0.name == "workspace-1" }?.chord.flags ?? [.control, .option]
        if state.nativeWorkspaces {
            guard state.desktopCount > 0 else { return }
            for number in 1...min(state.desktopCount, 16) {
                let entry = action(L10n.t("Escritorio \(number)", "Desktop \(number)"), .jumpToDesktop(number))
                entry.state = number == state.desktopNumber ? .on : .off
                if number <= 9 { setKey(entry, KeyChord(KeyCode.digits[number - 1], base)) }
                menu.addItem(entry)
            }
            if state.desktopNumber == nil { menu.addItem(disabled(L10n.t("Pantalla completa de macOS: Tessera no interviene", "macOS full screen: Tessera stays out"))) }
        } else if let desktop = state.desktopNumber {
            menu.addItem(disabled(L10n.t("Escritorio \(desktop) de macOS", "macOS desktop \(desktop)")))
            for group in state.groups {
                let entry = action(L10n.t("Grupo \(group.name) — \(group.windows) ventanas", "Group \(group.name) — \(group.windows) windows"), .command(.workspace(group.name)))
                entry.state = group.isActive ? .on : .off
                menu.addItem(entry)
            }
        }
    }

    private func buildLayoutSection(_ menu: NSMenu) {
        let layouts: [(LayoutMode, String)] = [(.tiles, "layout-tiles"), (.accordion, "layout-accordion"), (.monocle, "layout-monocle")]
        for (mode, name) in layouts {
            let entry = action(L10n.layoutName(mode.rawValue), .command(.layout(mode)))
            entry.state = state.layout == mode ? .on : .off
            if let binding = state.keymap.first(where: { $0.name == name }) { setKey(entry, binding.chord) }
            menu.addItem(entry)
        }
        let fullscreen = action(L10n.t("Pantalla completa de Tessera", "Tessera full screen"), .command(.toggleFullscreen))
        fullscreen.state = state.zoomed ? .on : .off
        if let binding = state.keymap.first(where: { $0.name == "fullscreen" }) { setKey(fullscreen, binding.chord) }
        menu.addItem(fullscreen)
        let balance = action(L10n.t("Igualar tamaños", "Balance sizes"), .command(.balanceSizes))
        if let binding = state.keymap.first(where: { $0.name == "balance-sizes" }) { setKey(balance, binding.chord) }
        menu.addItem(balance)
    }

    private func buildControlSection(_ menu: NSMenu) {
        switch state.status {
        case .active:
            let pause = action(L10n.t("Pausar Tessera", "Pause Tessera"), .togglePause)
            if let binding = state.keymap.first(where: { $0.name == "pause" }) { setKey(pause, binding.chord) }
            menu.addItem(pause)
        case .paused(.user):
            let resume = action(L10n.t("Reanudar Tessera", "Resume Tessera"), .togglePause)
            if let binding = state.keymap.first(where: { $0.name == "pause" }) { setKey(resume, binding.chord) }
            menu.addItem(resume)
        default:
            break
        }
        let gather = action(L10n.t("Reordenar todas las ventanas", "Re-tile all windows"), .gather)
        gather.isEnabled = state.status != .noPermission
        if state.status == .noPermission { gather.toolTip = L10n.t("Necesita el permiso de Accesibilidad", "Needs the Accessibility permission") }
        menu.addItem(gather)
        if state.canRevert {
            menu.addItem(action(L10n.t("Revertir a la disposición original", "Revert to the original layout"), .revertLayout))
        }
        menu.addItem(action(L10n.t("Olvidar tamaños aprendidos", "Forget learned sizes"), .forgetSizes))
        menu.addItem(action(L10n.t("Recargar configuración", "Reload configuration"), .reloadConfig))
    }

    private func buildActivity(_ menu: NSMenu) {
        guard !state.activity.isEmpty else { return }
        let submenu = NSMenu()
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        for entry in state.activity.prefix(10) {
            let item = NSMenuItem(title: "\(formatter.string(from: entry.at))  \(entry.notice.text)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }
        let parent = NSMenuItem(title: L10n.t("Actividad reciente", "Recent activity"), action: nil, keyEquivalent: "")
        parent.submenu = submenu
        menu.addItem(parent)
    }

    // MARK: Helpers

    private func register(_ action: UIAction) -> Int {
        actions.append(action)
        return actions.count - 1
    }

    private func action(_ title: String, _ action: UIAction) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        entry.target = self
        entry.tag = register(action)
        return entry
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    /// Shows the global shortcut next to the item (display only: menus do not own these keys).
    private func setKey(_ item: NSMenuItem, _ chord: KeyChord) {
        guard let name = KeyCode.names[chord.keyCode], name.count == 1 else { return }
        item.keyEquivalent = name.lowercased()
        var mask: NSEvent.ModifierFlags = []
        if chord.flags.contains(.control) { mask.insert(.control) }
        if chord.flags.contains(.option) { mask.insert(.option) }
        if chord.flags.contains(.shift) { mask.insert(.shift) }
        if chord.flags.contains(.command) { mask.insert(.command) }
        item.keyEquivalentModifierMask = mask
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        onAction?(actions[sender.tag])
    }

    @objc private func showKeys(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = L10n.t("Atajos de teclado de Tessera", "Tessera keyboard shortcuts")
        alert.informativeText = KeymapText.lines(state.keymap).joined(separator: "\n")
        alert.alertStyle = .informational
        NSApp.activate()
        alert.runModal()
    }

    @objc private func openAccessibility(_ sender: NSMenuItem) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitTiler(_ sender: NSMenuItem) {
        let bundles = ["AeroSpace": "bobko.aerospace", "Amethyst": "com.amethyst.Amethyst"]
        guard let name = sender.representedObject as? String, let bundle = bundles[name] else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).forEach { $0.terminate() }
    }
}
