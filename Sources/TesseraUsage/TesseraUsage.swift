public import Foundation
public import TesseraCore
import TesseraEngine

/// Tessera's usage statistics, the same consent flow as the author's other Mac apps: off until
/// the user says yes (asked once, a switch in the menu), then a count per feature per day sent to
/// `services/usage` in the EU. Never window titles, app names or layouts. Owner decision
/// 2026-11-20.
public enum TesseraUsage {
    /// `services/usage` on genesis, in the EU (the same endpoint as Quill, Ámbar and Batuta).
    public static let endpoint = URL(string: "https://usage.rrios.dev/v1/usage")!

    /// Every count Tessera may send. A name not here is never kept (`UsageReport.count`).
    public enum Count: String, CaseIterable, Sendable {
        case launches
        case focus
        case moves
        case workspaceSwitches = "workspace_switches"
        case windowsToWorkspace = "windows_to_workspace"
        case layoutChanges = "layout_changes"
        case orientationToggles = "orientation_toggles"
        case floatingToggles = "floating_toggles"
        case fullscreenToggles = "fullscreen_toggles"
        case balances
        case keyboardResizes = "keyboard_resizes"
        case mouseResizes = "mouse_resizes"
        case swaps
        case gathers
        case inserts
    }

    public static let counts: Set<String> = Set(Count.allCases.map(\.rawValue))

    /// The count one command adds to; nothing about which window, workspace or layout.
    public static func count(for command: Command) -> Count {
        switch command {
        case .focus, .focusWindow: .focus
        case .move: .moves
        case .workspace, .workspaceBackAndForth: .workspaceSwitches
        case .moveNodeToWorkspace: .windowsToWorkspace
        case .layout: .layoutChanges
        case .toggleOrientation: .orientationToggles
        case .toggleFloating, .setFloating: .floatingToggles
        case .toggleFullscreen: .fullscreenToggles
        case .balanceSizes: .balances
        case .resize: .keyboardResizes
        case .resizeWindow: .mouseResizes
        case .swapWindows: .swaps
        case .gatherWindows: .gathers
        case .insertWindow: .inserts
        }
    }

    @MainActor
    public static func makeReport(defaults: UserDefaults = .standard) -> UsageReport {
        UsageReport(app: "tessera", version: BuildInfo.version, allowedCounts: counts,
                    endpoint: .init(url: endpoint), defaults: defaults)
    }

    /// The menu item's title and what it says below.
    public static var toggleTitle: String {
        L10n.t("Compartir estadísticas de uso anónimas", "Share anonymous usage statistics")
    }

    public static var toggleHelp: String {
        L10n.t(
            "Una vez al día, cuántas veces usaste cada orden, la versión de Tessera y de macOS y tu idioma. Nunca títulos de ventanas, apps ni disposiciones.",
            "Once a day: how many times you used each command, the Tessera and macOS versions and your language. Never window titles, apps or layouts.")
    }

    /// Asked once, never again whatever the answer: the menu's switch changes it. A yes is a click,
    /// never a stray Return (`ConsentAlert`).
    @MainActor
    public static func ask(_ report: UsageReport) {
        report.setConsent(ConsentAlert.ask(
            title: L10n.t("¿Ayudas a mejorar Tessera?", "Help improve Tessera?"),
            message: L10n.t(
                "Tessera puede enviar una vez al día cuántas veces usaste cada orden, la versión y tu idioma. Nunca títulos de ventanas, apps ni disposiciones. Puedes cambiarlo cuando quieras en el menú de Tessera.",
                "Tessera can send, once a day, how many times you used each command, its version and your language. Never window titles, apps or layouts. You can change it any time in Tessera's menu."),
            yes: L10n.t("Compartir estadísticas", "Share statistics"),
            no: L10n.t("No, gracias", "No, thanks")))
    }
}

extension UsageReport {
    /// One use of one of Tessera's counts; nothing without consent.
    @MainActor
    public func count(_ count: TesseraUsage.Count, by amount: Int = 1) {
        self.count(count.rawValue, by: amount)
    }
}
