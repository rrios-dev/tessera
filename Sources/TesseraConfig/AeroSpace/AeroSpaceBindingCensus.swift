public import TesseraCore

/// Reads the key bindings out of an AeroSpace TOML config without a full TOML parser.
///
/// It recognises both `[mode.<name>.binding]` tables and dotted root keys
/// (`mode.main.binding.alt-h = '...'`). Values are ignored: only the chords matter,
/// because the importer needs to know which of them collide with typing on the
/// user's keyboard layout.
///
/// Limitation: a continuation line of a multi-line array whose string contains `=`
/// would be misread as a key. The census only sizes the import; the importer itself
/// uses a real TOML parser.
public enum AeroSpaceBindingCensus {
    static let modifierNames: Set<String> = ["alt", "ctrl", "cmd", "shift"]

    public struct Chord: Hashable, Sendable {
        public var modifiers: Set<String>
        public var key: String
    }

    public static func chords(inTOML text: String) -> [Chord] {
        var chords: [Chord] = []
        var inBindingTable = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine)).trimmingWhitespace()
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") {
                let header = line.trimmingCharacters(in: "[]").trimmingWhitespace()
                inBindingTable = isBindingTableHeader(header)
                continue
            }

            guard let equals = line.firstIndex(of: "=") else { continue }
            var key = String(line[..<equals]).trimmingWhitespace()
            key = unquote(key)

            if !inBindingTable {
                // Dotted form: mode.<name>.binding.<chord>
                let parts = key.split(separator: ".", maxSplits: 3).map(String.init)
                guard parts.count == 4, parts[0] == "mode", parts[2] == "binding" else { continue }
                key = unquote(parts[3])
            }

            if let chord = parseChord(key) {
                chords.append(chord)
            }
        }
        return chords
    }

    public static func census(inTOML text: String) -> BindingCensus {
        let chords = chords(inTOML: text)
        var byModifiers: [String: Int] = [:]
        var optionOnlyFamily = 0

        for chord in chords {
            let label = chord.modifiers.isEmpty ? "none" : chord.modifiers.sorted().joined(separator: "+")
            byModifiers[label, default: 0] += 1
            if chord.modifiers.contains("alt") && chord.modifiers.isSubset(of: ["alt", "shift"]) {
                optionOnlyFamily += 1
            }
        }
        return BindingCensus(total: chords.count, optionOnlyFamily: optionOnlyFamily, byModifiers: byModifiers)
    }

    static func parseChord(_ key: String) -> Chord? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        var modifiers: Set<String> = []
        var index = 0
        while index < parts.count - 1, modifierNames.contains(parts[index]) {
            modifiers.insert(parts[index])
            index += 1
        }
        let keyName = parts[index...].joined(separator: "-")
        guard !keyName.isEmpty else { return nil }
        return Chord(modifiers: modifiers, key: keyName)
    }

    static func isBindingTableHeader(_ header: String) -> Bool {
        let parts = header.split(separator: ".").map { unquote(String($0).trimmingWhitespace()) }
        return parts.count == 3 && parts[0] == "mode" && parts[2] == "binding"
    }

    /// Removes a trailing `#` comment that is not inside a quoted string.
    static func stripComment(_ line: String) -> String {
        var quote: Character?
        for index in line.indices {
            let character = line[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "#" {
                return String(line[..<index])
            }
        }
        return line
    }

    static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, let last = text.last,
              first == last, first == "'" || first == "\""
        else { return text }
        return String(text.dropFirst().dropLast())
    }
}

extension String {
    func trimmingWhitespace() -> String {
        trimmingCharacters(in: " \t\r")
    }

    func trimmingCharacters(in set: String) -> String {
        var start = startIndex
        var end = endIndex
        while start < end, set.contains(self[start]) { start = index(after: start) }
        while end > start, set.contains(self[index(before: end)]) { end = index(before: end) }
        return String(self[start..<end])
    }
}
