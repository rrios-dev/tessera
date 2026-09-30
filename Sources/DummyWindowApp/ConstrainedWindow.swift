import AppKit
import DummyWindowKit
import TesseraCore

/// A window that enforces its `WindowSpec` on every frame change, whoever asks for it.
///
/// Real apps enforce constraints in different places (delegates, content layout, their
/// own AX handlers); overriding `setFrame(_:display:)` makes the enforcement independent of
/// which path the Accessibility API takes, so spike S1 measures Tessera and not AppKit.
@MainActor
final class ConstrainedWindow: NSWindow {
    let spec: WindowSpec
    private var applyingInternalChange = false

    init(spec: WindowSpec) {
        self.spec = spec
        super.init(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        collectionBehavior = spec.fullScreenCapable ? [.fullScreenPrimary] : [.fullScreenNone]
        title = spec.title ?? "Dummy \(spec.id)"
        if let minSize = spec.minSize { self.minSize = NSSize(width: minSize.width, height: minSize.height) }
        if let maxSize = spec.maxSize { self.maxSize = NSSize(width: maxSize.width, height: maxSize.height) }
        contentView = LabelView(text: title)
        performInternally { setFrame(Coordinates.appKit(spec.frame), display: true) }
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        if spec.rigid && !applyingInternalChange {
            super.setFrame(frame, display: flag)
            return
        }
        let requested = Size(width: Int(frameRect.width.rounded()), height: Int(frameRect.height.rounded()))
        let accepted = SizeConstraints.accepted(requested, spec: spec)
        // Keep the top-left corner where the caller asked for it, as AppKit apps do.
        var constrained = frameRect
        constrained.origin.y = frameRect.maxY - CGFloat(accepted.height)
        constrained.size = NSSize(width: accepted.width, height: accepted.height)
        super.setFrame(constrained, display: flag)
    }

    func performInternally(_ body: () -> Void) {
        applyingInternalChange = true
        body()
        applyingInternalChange = false
    }

    var state: WindowState {
        WindowState(id: spec.id, frame: Coordinates.topLeft(frame), windowNumber: windowNumber)
    }
}

/// Draws the window id so a human watching the screen can tell test windows apart.
final class LabelView: NSView {
    let text: String

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let point = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (text as NSString).draw(at: point, withAttributes: attributes)
    }
}

/// AppKit uses a bottom-left origin relative to the primary screen; the wire protocol uses top-left.
@MainActor
enum Coordinates {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func appKit(_ rect: Rect) -> NSRect {
        NSRect(
            x: CGFloat(rect.x),
            y: primaryHeight - CGFloat(rect.y + rect.height),
            width: CGFloat(rect.width),
            height: CGFloat(rect.height)
        )
    }

    static func topLeft(_ rect: NSRect) -> Rect {
        Rect(
            x: Int(rect.minX.rounded()),
            y: Int((primaryHeight - rect.maxY).rounded()),
            width: Int(rect.width.rounded()),
            height: Int(rect.height.rounded())
        )
    }
}
