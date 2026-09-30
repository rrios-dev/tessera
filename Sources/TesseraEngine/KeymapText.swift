public import TesseraConfig
import TesseraCore

/// The keymap as text, for the cheatsheet, the menu and `tessera keys` (audit E5).
public enum KeymapText {
    public static func describe(_ action: KeyAction) -> String {
        switch action {
        case .togglePause: return L10n.t("Pausar / reanudar Tessera", "Pause / resume Tessera")
        case .command(let command):
            switch command {
            case .focus(let direction): return L10n.t("Foco \(word(direction))", "Focus \(direction.rawValue)")
            case .move(let direction): return L10n.t("Mover ventana \(word(direction))", "Move window \(direction.rawValue)")
            case .workspace(let name): return L10n.t("Ir al escritorio \(name)", "Go to desktop \(name)")
            case .moveNodeToWorkspace(let name): return L10n.t("Enviar ventana al escritorio \(name)", "Send window to desktop \(name)")
            case .workspaceBackAndForth: return L10n.t("Volver al escritorio anterior", "Back to the previous desktop")
            case .toggleFullscreen: return L10n.t("Pantalla completa de Tessera", "Tessera full screen")
            case .layout(let mode): return L10n.t("Disposición: ", "Layout: ") + L10n.layoutName(mode.rawValue)
            case .toggleOrientation: return L10n.t("Girar orientación", "Rotate orientation")
            case .toggleFloating: return L10n.t("Flotar / ordenar ventana", "Float / tile window")
            case .balanceSizes: return L10n.t("Igualar tamaños", "Balance sizes")
            case .resize(let dimension, let points):
                let grow = points > 0
                return dimension == .width
                    ? (grow ? L10n.t("Más ancho", "Wider") : L10n.t("Más estrecho", "Narrower"))
                    : (grow ? L10n.t("Más alto", "Taller") : L10n.t("Más bajo", "Shorter"))
            case .focusWindow, .swapWindows, .resizeWindow, .setFloating, .insertWindow, .gatherWindows: return "\(command)"
            }
        }
    }

    static func word(_ direction: Direction) -> String {
        switch direction {
        case .left: "a la izquierda"
        case .right: "a la derecha"
        case .up: "arriba"
        case .down: "abajo"
        }
    }

    /// One line per action, arrows folded into their letter twin, desktops 1–9 folded into one.
    public static func lines(_ bindings: [KeyBinding]) -> [String] {
        var lines: [String] = []
        var seenDesktops = false
        var seenSend = false
        for binding in bindings where !binding.name.hasSuffix("-arrow") {
            if binding.name.hasPrefix("workspace-"), binding.name != "workspace-back-and-forth" {
                guard !seenDesktops else { continue }
                seenDesktops = true
                let prefix = binding.chord.glyphs.dropLast()
                lines.append("\(prefix)1…9".padding(toLength: 12, withPad: " ", startingAt: 0) + L10n.t("Ir al escritorio 1…9", "Go to desktop 1…9"))
                continue
            }
            if binding.name.hasPrefix("move-node-to-workspace-") {
                guard !seenSend else { continue }
                seenSend = true
                let prefix = binding.chord.glyphs.dropLast()
                lines.append("\(prefix)1…9".padding(toLength: 12, withPad: " ", startingAt: 0) + L10n.t("Enviar ventana al escritorio 1…9", "Send window to desktop 1…9"))
                continue
            }
            lines.append(binding.chord.glyphs.padding(toLength: 12, withPad: " ", startingAt: 0) + describe(binding.action))
        }
        return lines
    }
}
