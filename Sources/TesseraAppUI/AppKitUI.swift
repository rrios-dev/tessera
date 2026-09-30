import AppKit
import TesseraConfig
public import TesseraCore
public import TesseraEngine

/// The engine's user interface on macOS: the menu bar item, the on-screen display, VoiceOver
/// announcements, the drop highlight and the shortcut overlay.
@MainActor
public final class AppKitUI: EngineUI {
    public var onAction: (@MainActor (UIAction) -> Void)? {
        didSet { menu?.onAction = onAction }
    }

    private var menu: StatusMenu?
    private let display = OnScreenDisplay()
    private let dropHighlight = DropHighlight()
    private let cheatsheet = Cheatsheet()
    private var state = UIState()

    /// - Parameter menu: false for runs without a menu bar item (tests, benchmarks).
    public init(menu: Bool) {
        if menu { self.menu = StatusMenu() }
    }

    public func update(_ state: UIState) {
        self.state = state
        menu?.update(state)
        cheatsheet.bindings = state.keymap
    }

    public func notify(_ notice: Notice) {
        // VoiceOver hears every notice, whether or not it is drawn (audit E2).
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: notice.text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
        if notice.onScreen { display.show(notice) }
    }

    public func showDropTarget(_ frame: Rect?) { dropHighlight.show(frame) }

    public func showCheatsheet(_ visible: Bool) {
        if visible { cheatsheet.show(state.keymap) } else { cheatsheet.hide() }
    }
}

/// Top-left global points to an AppKit frame on the primary screen's coordinate system.
@MainActor
func appKitFrame(_ rect: Rect) -> NSRect {
    let height = NSScreen.screens.first?.frame.height ?? 0
    return NSRect(x: rect.x, y: Int(height) - rect.y - rect.height, width: rect.width, height: rect.height)
}

/// A short, non-activating message near the bottom of the screen (plan §7: never steals focus,
/// ignores the mouse, respects Reduce Transparency and Reduce Motion).
@MainActor
final class OnScreenDisplay {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideToken = 0

    func show(_ notice: Notice) {
        let panel = self.panel ?? makePanel()
        label?.stringValue = notice.text
        label?.textColor = notice.kind == .error ? .systemRed : .labelColor
        let size = label?.fittingSize ?? NSSize(width: 300, height: 20)
        let width = min(max(size.width + 40, 220), 640)
        let height = size.height + 24
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrame(NSRect(x: visible.midX - width / 2, y: visible.minY + 80, width: width, height: height), display: true)
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        if !reduceMotion { NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 } }
        hideToken += 1
        let token = hideToken
        let seconds = max(1.5, Double(notice.text.count) / 18)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hideToken == token else { return }
                if reduceMotion {
                    panel.orderOut(nil)
                } else {
                    NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }, completionHandler: {
                        MainActor.assumeIsolated { if self.hideToken == token { panel.orderOut(nil) } }
                    })
                }
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let background: NSView
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            background = NSView()
            background.wantsLayer = true
            background.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.state = .active
            effect.blendingMode = .behindWindow
            background = effect
        }
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = 600
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: background.leadingAnchor, constant: 20),
        ])
        panel.contentView = background
        self.panel = panel
        self.label = label
        return panel
    }
}

/// A translucent rectangle over the tile a dragged window would swap with (audit E8).
@MainActor
final class DropHighlight {
    private var panel: NSPanel?

    func show(_ frame: Rect?) {
        guard let frame else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
            view.layer?.borderWidth = 3
            view.layer?.cornerRadius = 10
            panel.contentView = view
            panel.setAccessibilityElement(false)
            self.panel = panel
            return panel
        }()
        panel.setFrame(appKitFrame(frame).insetBy(dx: 6, dy: 6), display: true)
        panel.orderFrontRegardless()
    }
}

/// Every shortcut, grouped, shown while the base modifiers are held or from the menu.
@MainActor
final class Cheatsheet {
    var bindings: [KeyBinding] = []
    private var panel: NSPanel?

    func show(_ bindings: [KeyBinding]) {
        self.bindings = bindings
        let panel = self.panel ?? makePanel()
        let text = Self.text(bindings)
        let field = panel.contentView?.subviews.compactMap { $0 as? NSTextField }.first
        field?.stringValue = text
        let size = field?.fittingSize ?? NSSize(width: 400, height: 400)
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrame(NSRect(x: visible.midX - (size.width + 40) / 2, y: visible.midY - (size.height + 40) / 2,
                                  width: size.width + 40, height: size.height + 40), display: true)
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    static func text(_ bindings: [KeyBinding]) -> String {
        KeymapText.lines(bindings).joined(separator: "\n")
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.frame.origin = NSPoint(x: 20, y: 20)
        field.autoresizingMask = [.width, .height]
        effect.addSubview(field)
        panel.contentView = effect
        self.panel = panel
        return panel
    }
}
