import Testing
import TesseraCore
@testable import TesseraConfig

struct AeroSpaceBindingCensusTests {
    @Test func countsChordsInBindingTables() {
        let toml = """
        config-version = 2
        [mode.main.binding]
        alt-h = 'focus left'
        alt-shift-h = 'move left'   # comment with alt-x = 'ignored'
        cmd-alt-left = 'workspace prev'
        'alt-1' = 'workspace 1'

        [mode.service.binding]
        esc = ['reload-config', 'mode main']
        backspace = 'close-all-windows-but-current'

        [gaps]
        inner.horizontal = 0
        """
        let census = AeroSpaceBindingCensus.census(inTOML: toml)
        #expect(census.total == 6)
        #expect(census.optionOnlyFamily == 3)
        #expect(census.byModifiers["alt"] == 2)
        #expect(census.byModifiers["alt+shift"] == 1)
        #expect(census.byModifiers["alt+cmd"] == 1)
        #expect(census.byModifiers["none"] == 2)
    }

    @Test func acceptsDottedRootKeys() {
        let toml = """
        mode.main.binding.alt-j = 'focus down'
        mode.main.binding.ctrl-alt-k = 'focus up'
        gaps.outer.left = 8
        """
        let census = AeroSpaceBindingCensus.census(inTOML: toml)
        #expect(census.total == 2)
        #expect(census.optionOnlyFamily == 1)
    }

    @Test func keepsHyphenatedKeyNames() {
        let chord = AeroSpaceBindingCensus.parseChord("alt-shift-minus")
        #expect(chord?.modifiers == ["alt", "shift"])
        #expect(chord?.key == "minus")
        #expect(AeroSpaceBindingCensus.parseChord("alt-")?.key == nil)
    }

    @Test func ignoresNonBindingTables() {
        let toml = """
        [workspace-to-monitor-force-assignment]
        alt-1 = 'main'
        """
        #expect(AeroSpaceBindingCensus.census(inTOML: toml).total == 0)
    }
}
