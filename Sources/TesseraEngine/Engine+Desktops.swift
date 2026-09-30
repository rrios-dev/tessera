import Foundation
import TesseraCore
import TesseraPorts

extension Engine {
    /// Desktops Tessera will ever jump to: Mission Control allows 16 per display.
    static let maxDesktops = 16

    /// Workspace commands in native mode act on macOS's desktops. Returns false when the command
    /// is not a workspace command, so the model handles it.
    func handleNatively(_ command: Command) -> Bool {
        switch command {
        case .workspace(let name):
            refreshSpaces()
            let count = min(desktopOrder.count, Self.maxDesktops)
            // Only 1…N (audit B1): negative, zero, huge or non-numeric names never reach the keyboard.
            guard let target = Int(name), (1...max(1, count)).contains(target), count > 0 else {
                notify(Notice("desktop-missing", .info, count > 0 && Int(name) != nil
                    ? L10n.t("Solo hay \(count) escritorios. Añade más en Mission Control.", "There are only \(count) desktops. Add more in Mission Control.")
                    : L10n.t("«\(name)» no es un escritorio: usa un número del 1 al \(max(1, count)).", "“\(name)” is not a desktop: use a number from 1 to \(max(1, count)).")))
                return true
            }
            jump(to: target)
            return true
        case .workspaceBackAndForth:
            refreshSpaces()
            guard let previous = previousDesktop, (1...min(desktopOrder.count, Self.maxDesktops)).contains(previous) else { return true }
            jump(to: previous)
            return true
        case .moveNodeToWorkspace:
            // macOS 26 does not let an app move another app's window between desktops without
            // disabling SIP (ADR 0003). The user moves it and Tessera re-tiles both desktops.
            let times = noticeCounts["move-by-hand", default: 0]
            notify(Notice("move-by-hand", .info, L10n.t(
                "macOS no deja a Tessera mover ventanas entre escritorios: arrástrala manteniendo el clic y pulsa ⌃ y el número del escritorio.",
                "macOS does not let Tessera move windows between desktops: drag the window and, while holding it, press ⌃ and the desktop's number."
            ), onScreen: times < 3))
            return true
        default:
            return false
        }
    }

    /// Whether synthesized keys are safe right now (audit B3): never under Secure Input (a
    /// password field would receive them) and never while the login window or an authorisation
    /// dialog is in front.
    func mayPostKeys() -> Bool {
        if port.secureInputActive() {
            Metrics.count(.keysRefused)
            notify(Notice("secure-input", .warning, L10n.t(
                "Hay un campo de contraseña activo (Secure Input): Tessera no envía atajos de escritorio ahora.",
                "A password field is active (Secure Input): Tessera does not send desktop shortcuts now."
            )))
            return false
        }
        if let front = port.frontmostBundleID(), ["com.apple.loginwindow", "com.apple.SecurityAgent"].contains(front) {
            Metrics.count(.keysRefused)
            return false
        }
        return true
    }

    /// Whether macOS's shortcut `id` is enabled as `keyCode` with Control (and optionally fn).
    func symbolicEnabled(_ id: Int, keyCode: Int, hotkeys: [Int: SymbolicHotkey]) -> Bool {
        guard let hotkey = hotkeys[id], hotkey.enabled, hotkey.keyCode == keyCode else { return false }
        // Only Control among the four modifiers.
        return hotkey.modifiers & 0x1E0000 == 0x40000
    }

    /// Asks macOS to show desktop `target` (1-based), the way a person would.
    func jump(to target: Int) {
        guard let current = desktopNumber() ?? currentDesktop, target != current || desktopNumber() == nil else { return }
        guard mayPostKeys() else { return }
        let hotkeys = port.symbolicHotkeys()
        if target <= 9, symbolicEnabled(117 + target, keyCode: KeyCode.digits[target - 1], hotkeys: hotkeys) {
            Metrics.count(.keysPosted)
            port.postKey(KeyCode.digits[target - 1], flags: .control)
            return
        }
        // Control-Arrow steps over every Space of the display, full-screen ones included (E6).
        let order = port.spaceOrder()
        let targetSpace = desktopOrder[target - 1]
        guard let from = world.activeSpace.flatMap(order.firstIndex(of:)), let to = order.firstIndex(of: targetSpace) else { return }
        let steps = to - from
        let (id, key) = steps > 0 ? (81, KeyCode.rightArrow) : (79, KeyCode.leftArrow)
        guard symbolicEnabled(id, keyCode: key, hotkeys: hotkeys) else {
            notify(Notice("shortcuts-off", .warning, L10n.t(
                "Activa «Cambiar al escritorio N» o «Mover un espacio a la izquierda/derecha» en Ajustes › Teclado › Atajos › Mission Control para saltar entre escritorios.",
                "Turn on “Switch to Desktop N” or “Move left/right a space” in System Settings › Keyboard › Shortcuts › Mission Control to jump between desktops."
            )))
            return
        }
        for _ in 0..<min(abs(steps), Self.maxDesktops) {
            Metrics.count(.keysPosted)
            port.postKey(key, flags: [.control, .function])
        }
    }

    /// The previous desktop follows every change, whoever made it (trackpad, Mission Control,
    /// Tessera), so ⌃⌥Tab always goes back to where the user was (E6).
    func trackDesktopChange() {
        let now = desktopNumber()
        if let now, now != currentDesktop {
            if let current = currentDesktop { previousDesktop = current }
            currentDesktop = now
        }
    }
}
