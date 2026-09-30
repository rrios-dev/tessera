public import TesseraCore

/// A key combination, independent of Carbon so the keymap can be tested and printed.
public struct KeyChord: Sendable, Hashable, Codable {
    public var keyCode: Int
    public var flags: KeyFlags

    public init(_ keyCode: Int, _ flags: KeyFlags) {
        self.keyCode = keyCode
        self.flags = flags
    }

    /// The mask macOS stores in `com.apple.symbolichotkeys` for these modifiers.
    public var symbolicModifiers: Int {
        var mask = 0
        if flags.contains(.shift) { mask |= 0x20000 }
        if flags.contains(.control) { mask |= 0x40000 }
        if flags.contains(.option) { mask |= 0x80000 }
        if flags.contains(.command) { mask |= 0x100000 }
        return mask
    }

    /// "⌃⌥⇧H", the way macOS menus write shortcuts.
    public var glyphs: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + (KeyCode.names[keyCode] ?? "#\(keyCode)")
    }
}

/// Virtual key codes (`kVK_*`), as numbers so that nothing outside the platform needs Carbon.
public enum KeyCode {
    public static let a = 0, s = 1, d = 2, f = 3, h = 4, g = 5, z = 6, x = 7, c = 8, v = 9
    public static let b = 11, q = 12, w = 13, e = 14, r = 15, y = 16, t = 17, o = 31, u = 32
    public static let i = 34, p = 35, l = 37, j = 38, k = 40, n = 45, m = 46
    public static let comma = 43, period = 47, tab = 48, space = 49, escape = 53
    public static let leftArrow = 123, rightArrow = 124, downArrow = 125, upArrow = 126
    /// 1…9 in order.
    public static let digits = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    public static let names: [Int: String] = {
        var names: [Int: String] = [
            a: "A", s: "S", d: "D", f: "F", h: "H", g: "G", z: "Z", x: "X", c: "C", v: "V",
            b: "B", q: "Q", w: "W", e: "E", r: "R", y: "Y", t: "T", o: "O", u: "U",
            i: "I", p: "P", l: "L", j: "J", k: "K", n: "N", m: "M",
            comma: ",", period: ".", tab: "⇥", space: "Espacio", escape: "⎋",
            leftArrow: "←", rightArrow: "→", downArrow: "↓", upArrow: "↑",
        ]
        for (index, code) in digits.enumerated() { names[code] = String(index + 1) }
        return names
    }()

    /// Parses "ctrl-alt-shift-space", "cmd-h", "ctrl-alt-1" (the configuration grammar).
    public static func parseChord(_ text: String) -> KeyChord? {
        let parts = text.lowercased().split(separator: "-").map(String.init)
        guard let keyName = parts.last, !keyName.isEmpty else { return nil }
        var flags: KeyFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "ctrl", "control": flags.insert(.control)
            case "alt", "opt", "option": flags.insert(.option)
            case "shift": flags.insert(.shift)
            case "cmd", "command": flags.insert(.command)
            default: return nil
            }
        }
        let named: [String: Int] = [
            "space": space, "tab": tab, "comma": comma, "period": period, "escape": escape,
            "left": leftArrow, "right": rightArrow, "up": upArrow, "down": downArrow,
        ]
        if let code = named[keyName] { return KeyChord(code, flags) }
        if keyName.count == 1, let digit = Int(keyName), (1...9).contains(digit) { return KeyChord(digits[digit - 1], flags) }
        if keyName.count == 1, let code = names.first(where: { $0.value == keyName.uppercased() && $0.key < 50 })?.key {
            return KeyChord(code, flags)
        }
        return nil
    }
}
