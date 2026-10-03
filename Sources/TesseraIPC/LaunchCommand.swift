/// What `tessera` does when it is started without a command.
///
/// Opening Tessera.app from the Finder, the Dock, Launchpad or `open` starts the binary with no
/// arguments and no terminal attached. It used to print its usage and exit 64, so opening the app
/// did nothing anyone could see: only the launchd service, which passes `run`, ever started the
/// engine. Started that way it now runs the engine, exactly as `tessera run` would. Typed bare in
/// a terminal it still prints the usage.
///
/// A second engine is not a risk: `engine.lock` lets one run per state directory, and the one
/// that finds it taken exits 0.
public enum LaunchCommand {
    /// The arguments to run with. `inAppBundle`: the executable lives inside a `.app`.
    /// `interactive`: standard input is a terminal.
    public static func arguments(given arguments: [String], inAppBundle: Bool, interactive: Bool) -> [String] {
        // Process serial numbers that older launchers appended; macOS 15 no longer passes them.
        let arguments = arguments.filter { !$0.hasPrefix("-psn_") }
        guard arguments.isEmpty, inAppBundle, !interactive else { return arguments }
        return ["run"]
    }
}
