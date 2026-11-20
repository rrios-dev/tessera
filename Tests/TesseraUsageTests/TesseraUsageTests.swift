import Foundation
import TesseraCore
import Testing
import TesseraUsage

/// Tessera's usage statistics (owner decision 2026-11-20): nothing kept before a yes, one count per
/// command kind, and only names `services/usage` accepts.
@Suite("Tessera usage statistics")
@MainActor
struct TesseraUsageTests {
    private func freshDefaults() -> UserDefaults {
        let name = "TesseraUsageTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let afterToday = Date().addingTimeInterval(2 * 86_400)

    @Test("nothing is kept before the user says yes")
    func nothingWithoutConsent() {
        let report = TesseraUsage.makeReport(defaults: freshDefaults())
        #expect(report.consent == nil)
        report.count(.layoutChanges)
        report.setConsent(true)
        #expect(report.preview(now: afterToday).isEmpty)
    }

    @Test("after a yes, commands are counted by kind and sent as Tessera's")
    func countsByKind() throws {
        let report = TesseraUsage.makeReport(defaults: freshDefaults())
        report.setConsent(true)
        for command: Command in [.focus(.left), .focus(.right), .balanceSizes, .workspace("2")] {
            report.count(TesseraUsage.count(for: command))
        }
        let day = try #require(report.preview(now: afterToday).first)
        #expect(day.app == "tessera")
        #expect(day.counts == ["focus": 2, "balances": 1, "workspace_switches": 1])
    }

    @Test("a no deletes what was kept")
    func noDeletes() {
        let report = TesseraUsage.makeReport(defaults: freshDefaults())
        report.setConsent(true)
        report.count(.launches)
        report.setConsent(false)
        report.setConsent(true)
        #expect(report.preview(now: afterToday).isEmpty)
    }

    /// `services/usage` refuses a whole request with one name outside `^[a-z][a-z_]{0,31}$`, and a
    /// version outside `^\d{1,3}(\.\d{1,3}){0,3}$`.
    @Test("every name and the version are ones the server accepts")
    func shapesTheServerAccepts() {
        let name = /^[a-z][a-z_]{0,31}$/
        for count in TesseraUsage.counts { #expect(count.wholeMatch(of: name) != nil, "\(count)") }
        let report = TesseraUsage.makeReport(defaults: freshDefaults())
        #expect(report.version.wholeMatch(of: /^\d{1,3}(\.\d{1,3}){0,3}$/) != nil)
    }
}
