import Testing
@testable import TesseraIPC

struct LaunchCommandTests {
    @Test func openingTheAppRunsTheEngine() {
        #expect(LaunchCommand.arguments(given: [], inAppBundle: true, interactive: false) == ["run"])
    }

    @Test func aBareCommandInATerminalStillPrintsTheUsage() {
        #expect(LaunchCommand.arguments(given: [], inAppBundle: true, interactive: true) == [])
        #expect(LaunchCommand.arguments(given: [], inAppBundle: false, interactive: false) == [])
    }

    @Test func explicitCommandsAreLeftAlone() {
        #expect(LaunchCommand.arguments(given: ["run"], inAppBundle: true, interactive: false) == ["run"])
        #expect(LaunchCommand.arguments(given: ["service", "install"], inAppBundle: true, interactive: false) == ["service", "install"])
        #expect(LaunchCommand.arguments(given: ["debug", "check"], inAppBundle: false, interactive: true) == ["debug", "check"])
    }

    @Test func dropsAProcessSerialNumber() {
        #expect(LaunchCommand.arguments(given: ["-psn_0_123456"], inAppBundle: true, interactive: false) == ["run"])
    }
}
