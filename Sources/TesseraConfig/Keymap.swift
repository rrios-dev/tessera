public import TesseraCore
public import TesseraPorts

/// What a key does: a model command, or one of the few actions that belong to the app.
public enum KeyAction: Sendable, Hashable {
    case command(Command)
    case togglePause
}

public struct KeyBinding: Sendable, Hashable {
    /// The action's name in the configuration file (`[keys]` section).
    public var name: String
    public var chord: KeyChord
    public var action: KeyAction

    public init(name: String, chord: KeyChord, action: KeyAction) {
        self.name = name
        self.chord = chord
        self.action = action
    }
}

/// The default keymap and its overrides.
///
/// Control+Option is VoiceOver's modifier, so with VoiceOver on every chord gains Command
/// (plan §7). Toggle-floating is Control+Option+Shift+Space: Control+Option+Space selects the
/// next input source on macOS.
public enum Keymap {
    public static func modifiers(voiceOver: Bool) -> KeyFlags {
        voiceOver ? [.control, .option, .command] : [.control, .option]
    }

    public static func defaults(voiceOver: Bool = false) -> [KeyBinding] {
        let base = modifiers(voiceOver: voiceOver)
        let shifted = base.union(.shift)
        var result: [KeyBinding] = []
        func add(_ name: String, _ key: Int, _ flags: KeyFlags, _ action: KeyAction) {
            result.append(KeyBinding(name: name, chord: KeyChord(key, flags), action: action))
        }
        let directions: [(String, Int, Int, Direction)] = [
            ("left", KeyCode.h, KeyCode.leftArrow, .left), ("right", KeyCode.l, KeyCode.rightArrow, .right),
            ("up", KeyCode.k, KeyCode.upArrow, .up), ("down", KeyCode.j, KeyCode.downArrow, .down),
        ]
        for (name, letter, arrow, direction) in directions {
            add("focus-\(name)", letter, base, .command(.focus(direction)))
            add("focus-\(name)-arrow", arrow, base, .command(.focus(direction)))
            add("move-\(name)", letter, shifted, .command(.move(direction)))
            add("move-\(name)-arrow", arrow, shifted, .command(.move(direction)))
        }
        for (index, key) in KeyCode.digits.enumerated() {
            add("workspace-\(index + 1)", key, base, .command(.workspace(String(index + 1))))
            add("move-node-to-workspace-\(index + 1)", key, shifted, .command(.moveNodeToWorkspace(String(index + 1))))
        }
        add("workspace-back-and-forth", KeyCode.tab, base, .command(.workspaceBackAndForth))
        add("fullscreen", KeyCode.f, base, .command(.toggleFullscreen))
        add("layout-tiles", KeyCode.t, base, .command(.layout(.tiles)))
        add("layout-accordion", KeyCode.a, base, .command(.layout(.accordion)))
        add("layout-monocle", KeyCode.m, base, .command(.layout(.monocle)))
        add("toggle-orientation", KeyCode.r, base, .command(.toggleOrientation))
        add("toggle-floating", KeyCode.space, shifted, .command(.toggleFloating))
        add("balance-sizes", KeyCode.b, base, .command(.balanceSizes))
        add("grow-width", KeyCode.period, base, .command(.resize(.width, points: 50)))
        add("shrink-width", KeyCode.comma, base, .command(.resize(.width, points: -50)))
        add("grow-height", KeyCode.period, shifted, .command(.resize(.height, points: 50)))
        add("shrink-height", KeyCode.comma, shifted, .command(.resize(.height, points: -50)))
        add("pause", KeyCode.p, base, .togglePause)
        return result
    }

    public struct Override: Sendable, Hashable {
        public var name: String
        /// Nil removes the binding ("none").
        public var chord: KeyChord?
    }

    /// Applies `[keys]` overrides: `name = "ctrl-alt-x"` or `name = "none"`.
    /// - Returns: the bindings and one message per override that could not be applied.
    public static func applying(_ overrides: [String: String], to bindings: [KeyBinding]) -> (bindings: [KeyBinding], errors: [String]) {
        var result = bindings
        var errors: [String] = []
        for (name, value) in overrides.sorted(by: { $0.key < $1.key }) {
            guard let index = result.firstIndex(where: { $0.name == name }) else {
                errors.append("unknown action '\(name)'")
                continue
            }
            if value == "none" {
                result.remove(at: index)
                continue
            }
            guard let chord = KeyCode.parseChord(value) else {
                errors.append("cannot read the keys '\(value)' for '\(name)'")
                continue
            }
            result[index].chord = chord
        }
        // Two actions on one chord: the later override would silently win; say so instead.
        var seen: [KeyChord: String] = [:]
        for binding in result {
            if let other = seen[binding.chord] { errors.append("'\(binding.name)' and '\(other)' share \(binding.chord.glyphs)") }
            seen[binding.chord] = binding.name
        }
        return (result, errors)
    }

    /// macOS shortcuts (enabled symbolic hotkeys) that use the same chord as a binding.
    public static func clashes(_ bindings: [KeyBinding], with symbolic: [Int: SymbolicHotkey]) -> [(binding: KeyBinding, symbolicID: Int)] {
        var result: [(KeyBinding, Int)] = []
        for binding in bindings {
            // Only the four modifier bits matter; macOS adds the fn bit for arrows.
            let mask = binding.chord.symbolicModifiers
            for (id, hotkey) in symbolic.sorted(by: { $0.key < $1.key })
            where hotkey.enabled && hotkey.keyCode == binding.chord.keyCode && (hotkey.modifiers & 0x1E0000) == mask {
                result.append((binding, id))
            }
        }
        return result
    }
}
