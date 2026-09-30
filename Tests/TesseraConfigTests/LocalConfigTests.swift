import Testing
import TesseraCore
import TesseraPorts
@testable import TesseraConfig

struct LocalConfigTests {
    @Test func parsesEverySection() throws {
        let config = try LocalConfig.parse("""
        # comment
        [general]
        inner-gap = 8          # trailing comment
        outer-gap = 4
        default-layout = "accordion"
        overflow = "float-largest"
        emulated-workspaces = true

        [apps]
        exclude = ["com.apple.systempreferences", "com.example.x"]
        float = []

        [keys]
        toggle-floating = "ctrl-alt-shift-space"
        layout-accordion = "none"
        """)
        #expect(config.innerGap == 8 && config.outerGap == 4)
        #expect(config.defaultLayout == .accordion)
        #expect(config.overflow == .floatLargest)
        #expect(config.emulatedWorkspaces == true)
        #expect(config.exclude == ["com.apple.systempreferences", "com.example.x"])
        #expect(config.float.isEmpty)
        #expect(config.keys["layout-accordion"] == "none")
        let settings = config.applied(to: WorldSettings())
        #expect(settings.innerGap == 8 && settings.defaultLayout == .accordion && settings.overflow == .floatLargest)
    }

    @Test func reportsErrorsWithTheirLine() {
        #expect(throws: LocalConfig.Failure(line: 2, message: "inner-gap must be a number")) {
            try LocalConfig.parse("[general]\ninner-gap = \"wide\"")
        }
        #expect(throws: LocalConfig.Failure.self) { try LocalConfig.parse("[general]\ninner-gap = 900") }
        #expect(throws: LocalConfig.Failure.self) { try LocalConfig.parse("[nonsense]") }
        #expect(throws: LocalConfig.Failure.self) { try LocalConfig.parse("orphan = 1") }
        #expect(throws: LocalConfig.Failure.self) { try LocalConfig.parse("[apps]\nexclude = [\"a\"") }
    }

    @Test func unknownKeysAreWarningsNotErrors() throws {
        let config = try LocalConfig.parse("[general]\nsparkles = true")
        #expect(config.warnings.count == 1)
    }

    @Test func keyOverridesApplyAndConflictsAreReported() {
        let (bindings, errors) = Keymap.applying(
            ["layout-monocle": "ctrl-alt-shift-m", "layout-accordion": "none", "balance-sizes": "ctrl-alt-f", "nope": "ctrl-a"],
            to: Keymap.defaults()
        )
        #expect(bindings.first { $0.name == "layout-monocle" }?.chord == KeyChord(KeyCode.m, [.control, .option, .shift]))
        #expect(!bindings.contains { $0.name == "layout-accordion" })
        #expect(errors.contains { $0.contains("unknown action 'nope'") })
        #expect(errors.contains { $0.contains("share") }, "balance-sizes now collides with fullscreen")
    }

    @Test func chordsParse() {
        #expect(KeyCode.parseChord("ctrl-alt-1") == KeyChord(KeyCode.digits[0], [.control, .option]))
        #expect(KeyCode.parseChord("cmd-shift-left") == KeyChord(KeyCode.leftArrow, [.command, .shift]))
        #expect(KeyCode.parseChord("hyper-x") == nil)
        #expect(KeyCode.parseChord("ctrl-") == nil)
    }

    @Test func voiceOverAddsCommandToEveryChord() {
        #expect(Keymap.defaults(voiceOver: true).allSatisfy { $0.chord.flags.contains([.control, .option, .command]) })
        #expect(Keymap.defaults(voiceOver: false).allSatisfy { !$0.chord.flags.contains(.command) })
    }
}
