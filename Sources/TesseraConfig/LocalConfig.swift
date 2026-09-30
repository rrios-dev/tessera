public import TesseraCore

/// `~/.config/tessera/tessera.local.toml`: the small hand-written overlay the plan's Settings
/// app will later write for the user (plan D4). A strict subset of TOML — sections, `key = value`
/// with integers, booleans, strings and single-line string arrays, `#` comments.
///
/// ```toml
/// [general]
/// inner-gap = 8
/// outer-gap = 8
/// default-layout = "tiles"     # tiles | accordion | monocle
/// overflow = "accordion"       # accordion | stack | float-largest | allow
/// emulated-workspaces = false
///
/// [apps]
/// exclude = ["com.apple.systempreferences"]
/// float = ["us.zoom.xos"]
///
/// [keys]
/// toggle-floating = "ctrl-alt-shift-space"
/// layout-accordion = "none"
/// ```
public struct LocalConfig: Sendable, Equatable {
    public var innerGap: Int?
    public var outerGap: Int?
    public var defaultLayout: LayoutMode?
    public var overflow: OverflowPolicy?
    public var emulatedWorkspaces: Bool?
    public var exclude: [String] = []
    public var float: [String] = []
    public var keys: [String: String] = [:]
    /// Keys the parser did not recognise; reported, never fatal.
    public var warnings: [String] = []

    public init() {}

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public var line: Int
        public var message: String
        public var description: String { "line \(line): \(message)" }
    }

    enum Value: Equatable {
        case int(Int), bool(Bool), string(String), strings([String])
    }

    public static func parse(_ text: String) throws(Failure) -> LocalConfig {
        var config = LocalConfig()
        var section = ""
        for (offset, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let number = offset + 1
            let line = stripComment(String(raw)).trimmed
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]"), line.count > 2 else { throw Failure(line: number, message: "malformed section header") }
                section = String(line.dropFirst().dropLast()).trimmed
                guard ["general", "apps", "keys"].contains(section) else { throw Failure(line: number, message: "unknown section [\(section)]") }
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { throw Failure(line: number, message: "expected key = value") }
            let key = String(line[..<equals]).trimmed
            let value = try parseValue(String(line[line.index(after: equals)...]).trimmed, line: number)
            try config.assign(section: section, key: key, value: value, line: number)
        }
        return config
    }

    mutating func assign(section: String, key: String, value: Value, line: Int) throws(Failure) {
        func int() throws(Failure) -> Int {
            guard case .int(let number) = value else { throw Failure(line: line, message: "\(key) must be a number") }
            guard (0...WorldSettings.maxGap).contains(number) else { throw Failure(line: line, message: "\(key) must be between 0 and \(WorldSettings.maxGap)") }
            return number
        }
        func string() throws(Failure) -> String {
            guard case .string(let text) = value else { throw Failure(line: line, message: "\(key) must be a string") }
            return text
        }
        func strings() throws(Failure) -> [String] {
            guard case .strings(let list) = value else { throw Failure(line: line, message: "\(key) must be a list of strings") }
            return list
        }
        switch (section, key) {
        case ("general", "inner-gap"): innerGap = try int()
        case ("general", "outer-gap"): outerGap = try int()
        case ("general", "default-layout"):
            let name = try string()
            guard let layout = LayoutMode(rawValue: name) else { throw Failure(line: line, message: "unknown layout '\(name)'") }
            defaultLayout = layout
        case ("general", "overflow"):
            let name = try string()
            let map: [String: OverflowPolicy] = ["accordion": .accordion, "stack": .stack, "float-largest": .floatLargest, "allow": .allow]
            guard let policy = map[name] else { throw Failure(line: line, message: "unknown overflow policy '\(name)'") }
            overflow = policy
        case ("general", "emulated-workspaces"):
            guard case .bool(let flag) = value else { throw Failure(line: line, message: "\(key) must be true or false") }
            emulatedWorkspaces = flag
        case ("apps", "exclude"): exclude = try strings()
        case ("apps", "float"): float = try strings()
        case ("keys", _): keys[key] = try string()
        case ("", _): throw Failure(line: line, message: "'\(key)' is outside any section")
        default: warnings.append("line \(line): unknown key '\(key)' in [\(section)]")
        }
    }

    static func parseValue(_ text: String, line: Int) throws(Failure) -> Value {
        if text == "true" { return .bool(true) }
        if text == "false" { return .bool(false) }
        if let number = Int(text) { return .int(number) }
        if text.hasPrefix("\"") { return .string(try quoted(text, line: line)) }
        if text.hasPrefix("[") {
            guard text.hasSuffix("]") else { throw Failure(line: line, message: "lists must close on the same line") }
            let inner = String(text.dropFirst().dropLast()).trimmed
            if inner.isEmpty { return .strings([]) }
            var items: [String] = []
            for part in inner.split(separator: ",") {
                let item = String(part).trimmed
                if item.isEmpty { continue }
                items.append(try quoted(item, line: line))
            }
            return .strings(items)
        }
        throw Failure(line: line, message: "cannot read value '\(text)'")
    }

    static func quoted(_ text: String, line: Int) throws(Failure) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { throw Failure(line: line, message: "unterminated string") }
        let body = String(text.dropFirst().dropLast())
        guard !body.contains("\"") else { throw Failure(line: line, message: "quotes inside strings are not supported") }
        return body
    }

    static func stripComment(_ line: String) -> String {
        var inString = false
        for (index, character) in line.enumerated() {
            if character == "\"" { inString.toggle() }
            if character == "#", !inString { return String(line.prefix(index)) }
        }
        return line
    }

    /// Applies the overlay to the engine's settings.
    public func applied(to settings: WorldSettings) -> WorldSettings {
        WorldSettings(
            defaultLayout: defaultLayout ?? settings.defaultLayout,
            innerGap: innerGap ?? settings.innerGap,
            outerGap: outerGap ?? settings.outerGap,
            accordionPadding: settings.accordionPadding,
            overflow: overflow ?? settings.overflow
        )
    }
}

extension String {
    var trimmed: String {
        var scalars = Substring(self)
        while let first = scalars.first, first == " " || first == "\t" || first == "\r" { scalars = scalars.dropFirst() }
        while let last = scalars.last, last == " " || last == "\t" || last == "\r" { scalars = scalars.dropLast() }
        return String(scalars)
    }
}
