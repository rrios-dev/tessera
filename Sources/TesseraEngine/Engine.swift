public import Foundation
import TesseraConfig
public import TesseraCore
import TesseraIPC
public import TesseraPorts

/// Runs Tessera on the primary monitor: observes macOS through a `SystemPort`, reduces events into
/// the `World`, renders it, applies frames through each app's `AppDriver` and reads back what every
/// window really accepted.
///
/// The work is split by concern across `Engine+*.swift`: discovery (which windows exist), reconcile
/// (placing and learning), hiding (the journal), desktops (native Spaces), mouse, keys and IPC.
@MainActor
public final class Engine {
    public struct Options: Sendable {
        /// When set, only these processes are managed (sandboxed testing next to another WM).
        public var onlyPIDs: Set<Int32>?
        public var excludedBundleIDs: Set<String> = ["bobko.aerospace"]
        /// Apps whose windows always float (configuration `[apps] float`).
        public var floatingBundleIDs: Set<String> = []
        public var hotkeys = true
        public var verbose = false
        /// Tiles every standard window, ignoring the dialog heuristics. Developer-only.
        public var tileAll = false
        /// Observe and compute everything, move nothing, never touch the journal.
        public var dryRun = false
        /// Workspaces are macOS's own desktops: `workspace N` jumps to desktop N. When false,
        /// Tessera emulates groups inside each desktop by hiding windows in a corner.
        public var nativeWorkspaces = true
        public var settings = WorldSettings()
        /// State directory (socket, journal, log…); nil is the owner's default.
        public var stateDirectory: URL?
        /// The local configuration overlay; nil is `~/.config/tessera/tessera.local.toml`.
        public var configFile: URL?
        /// Ask macOS to show the Accessibility prompt when the permission is missing.
        public var promptForPermission = true
        /// Serve the CLI socket.
        public var ipc = true

        public init() {}
    }

    // MARK: Collaborators

    let port: any SystemPort
    let ui: any EngineUI
    public let timing: Timing
    public let options: Options
    public let paths: StatePaths
    public let log: Log

    // MARK: Model and status

    public private(set) var world: World
    public private(set) var status: EngineStatus = .starting
    var settings: WorldSettings
    var localConfig = LocalConfig()
    var configErrors: [String] = []
    public let startedAt: Date

    // MARK: Apps and windows

    var drivers: [Int32: any AppDriver] = [:]
    var appInfo: [Int32: RunningApp] = [:]
    /// Bumped on every adopt and release: a completion from an older generation is stale (C5).
    var generation: [Int32: Int] = [:]
    var generationCounter = 0
    var lastUnresponsiveScan: [Int32: Date] = [:]
    var rescanScheduled: Set<Int32> = []
    /// Windows seen and not manageable (panels, popovers): never rediscovered as "missed".
    var rejected: Set<WindowID> = []
    /// Windows of the active Space drawn at the last audit, to detect "stopped being drawn".
    var wasOnScreen: Set<WindowID> = []
    var subroles: [WindowID: String] = [:]
    /// When each window was first seen: apps size their windows while they open, so nothing is
    /// learned from a window's first moments.
    var firstSeen: [WindowID: Date] = [:]

    // MARK: Reconciliation

    /// Last frame read back from each window.
    var observed: [WindowID: Rect] = [:]
    /// Frame last requested for each window, and how many times in a row it was refused.
    var requested: [WindowID: (target: Rect, attempts: Int)] = [:]
    var inFlight: Set<WindowID> = []
    var lastWrite: [WindowID: Date] = [:]
    /// Refused writes per window, with the target each refused.
    var writeLog: [WindowID: [(at: Date, target: Rect)]] = [:]
    var backoff: [WindowID: (until: Date, interval: TimeInterval)] = [:]
    var driftBudget: [WindowID: [Date]] = [:]
    var factCandidates: [WindowID: WindowFacts] = [:]
    var contradictions: [WindowID: Int] = [:]
    var alignment: [WindowID: (target: Rect, retries: Int, last: Date)] = [:]
    /// The last target each window answered with a different frame: a settled window that
    /// refused its target is in a terminal state, not drifting, and is not rewritten.
    var refusedTarget: [WindowID: Rect] = [:]
    var lastFront: [WindowID] = []
    var pendingFocus: (id: WindowID, at: Date)?
    /// The last window Tessera asked macOS to focus. A focus report for another window that
    /// arrives right after is the echo of an earlier request, not the user's doing.
    var lastFocusRequest: (id: WindowID, at: Date)?
    var renderScheduled = false
    /// A placement was skipped because its window was being written: render again when the
    /// write completes, or the skipped placement would wait for an unrelated event.
    var deferredRender = false
    var screens: [ScreenInfo] = []
    var edgeClamp = EdgeClamp()
    var edgeClampStore = EdgeClampStore()
    var factStore = FactStore()
    var lastPlanFlags: (overflowed: Int, reflowed: Int, autoFloated: Int) = (0, 0, 0)

    // MARK: Hiding

    var journal: Journal
    var originalLayout: OriginalLayout

    // MARK: Desktops

    var lastScannedSpace: SpaceID?
    /// Native desktops of the primary display in Mission Control order.
    var desktopOrder: [SpaceID] = []
    var previousDesktop: Int?
    var currentDesktop: Int?

    // MARK: Mouse

    var mouseIsDown = false
    /// Tiled windows the user moved or resized while holding the mouse button.
    var draggedByUser: Set<WindowID> = []
    /// Between the button going up and the drop being resolved nothing is placed.
    var resolvingDrop = false
    var dropTarget: Rect?
    /// Each dragged window's frame when the drag began: tells a move from a resize.
    var dragStart: [WindowID: Rect] = [:]

    // MARK: Keys

    var keymap: [KeyBinding] = []
    var registered: [KeyBinding] = []
    var modifiersHeld: KeyFlags = []
    var cheatsheetToken = 0
    var cheatsheetVisible = false

    // MARK: Timers, IPC, persistence

    var auditTimer: Repeater?
    var auditInterval: TimeInterval = 2
    var auditBurst = 0
    var lastActivity: Date
    var permissionTimer: Repeater?
    var server: LineSocket.Server?
    var stateLock: StateLock?
    var ipcBudget = RateLimiter(rate: 10, burst: 20)
    var focusBudget = RateLimiter(rate: 4, burst: 6)
    var cachedState: (at: Date, world: World, reply: Data)?
    /// Targets whose window kept its own size but drifted off the tile's origin; corrected once.
    var positionCorrected: [WindowID: (target: Rect, count: Int)] = [:]
    var worldSaveScheduled = false
    /// Set when quitting starts: nothing is placed or hidden any more, or a late render would
    /// hide again a window the shutdown just restored.
    var shuttingDown = false
    var crashGuard = CrashGuard()

    // MARK: Feedback

    var activity: [ActivityEntry] = []
    var noticeCounts: [String: Int] = [:]
    var lastUIState: UIState?
    var warnedOnce: Set<String> = []

    /// Called when the user picks Quit; the host restores windows and exits.
    public var onQuitRequested: (() -> Void)?

    public init(options: Options = Options(), port: any SystemPort, ui: any EngineUI, timing: Timing = .production, log: Log? = nil) {
        self.options = options
        self.port = port
        self.ui = ui
        self.timing = timing
        paths = StatePaths(directory: options.stateDirectory)
        self.log = log ?? Log(url: nil)
        self.log.verbose = options.verbose
        settings = options.settings
        world = World(settings: options.settings)
        startedAt = port.now()
        lastActivity = port.now()
        journal = Journal(bootSession: port.bootSessionID())
        originalLayout = OriginalLayout(bootSession: port.bootSessionID(), capturedAt: port.now())
    }

    public enum StartError: Error, CustomStringConvertible {
        case alreadyRunning(String)
        case stateDirectory(String)

        public var description: String {
            switch self {
            case .alreadyRunning(let detail): detail
            case .stateDirectory(let detail): "cannot use the state directory: \(detail)"
            }
        }
    }

    // MARK: - Lifecycle

    /// Takes the state directory, starts listening to macOS and, once the Accessibility
    /// permission is there, starts tiling. Without it the engine waits in `.noPermission`.
    public func start() throws {
        do {
            try paths.prepare()
            stateLock = try StateLock(paths.lock)
        } catch let failure as StateLock.Failure {
            throw StartError.alreadyRunning(failure.description)
        } catch {
            throw StartError.stateDirectory("\(error)")
        }
        log.notice("\(BuildInfo.description) starting, pid \(getpid()), state \(paths.directory.path), boot \(port.bootSessionID())")
        loadPersistentState()
        loadConfig(reporting: false)

        ui.onAction = { [weak self] action in self?.perform(action) }
        port.onEvent = { [weak self] event in self?.handle(event) }
        port.startMonitoring()
        if options.ipc { startIPC() }

        if !options.dryRun {
            var guardState = crashGuard
            let looping = guardState.recordStart(now: port.now())
            crashGuard = guardState
            try? SecureFile.writeJSON(crashGuard, to: paths.starts)
            if looping {
                enterSafeMode()
                return
            }
        }
        guard port.isTrusted(prompt: options.promptForPermission) else {
            enterNoPermission(initially: true)
            return
        }
        activate()
    }

    /// Everything that needs the permission: adopt apps, restore what a previous run left hidden,
    /// check for other tilers and Stage Manager, register hotkeys, start auditing.
    func activate() {
        permissionTimer?.cancel()
        permissionTimer = nil
        refreshScreen(force: true)
        refreshSpaces()
        trackDesktopChange()
        let restored = port.armEnhancedUIJournal(at: paths.enhancedUI)
        if !restored.isEmpty { log.notice("turned AXEnhancedUserInterface back on for \(restored.count) apps a previous run left off", .ax) }
        restoreWorldSnapshot()
        status = .active
        for app in port.runningApps() where isManaged(app) { adopt(app) }
        // Apps adopted before the permission was lost are read again.
        rescanAll()
        refreshFocus()
        rescueSweep(reason: "start")
        preflight()
        registerKeymap()
        scheduleAuditTimer(fast: true)
        scheduleRender()
        publishUI()
        log.notice("active: \(drivers.count) apps, Spaces via SkyLight: \(port.spacesAvailable), status \(status)")
    }

    /// Puts every hidden window back, confirms each restore, keeps what could not be confirmed
    /// for the next run, and records a clean exit.
    public func shutdown(reason: String = "quit", completion: @escaping @MainActor () -> Void) {
        log.notice("shutting down: \(reason)")
        guard !shuttingDown else { return }
        shuttingDown = true
        auditTimer?.cancel()
        permissionTimer?.cancel()
        port.unregisterHotkeys()
        server?.stop()
        server = nil
        flushWorldSnapshot()
        let finish: @MainActor () -> Void = { [self] in
            port.stopMonitoring()
            stateLock = nil
            crashGuard.recordCleanExit()
            try? SecureFile.writeJSON(crashGuard, to: paths.starts)
            if !journal.hidden.isEmpty {
                log.notice("\(journal.hidden.count) hidden windows could not be confirmed restored; the next run restores them", .journal)
            }
            log.notice("exit: \(reason)")
            completion()
        }
        guard !options.dryRun, !journal.hidden.isEmpty, port.isTrusted(prompt: false) else {
            finish()
            return
        }
        restoreAll(timeout: timing.shutdownWait) { finish() }
    }

    // MARK: - Status transitions

    func setStatus(_ next: EngineStatus) {
        guard status != next else { return }
        let before = status
        status = next
        log.notice("status \(before) → \(next)")
        publishUI()
    }

    /// The permission is missing: hotkeys off, nothing moves, hidden windows stay where they are
    /// (they cannot be moved without the permission) and come back once it returns (plan §3).
    func enterNoPermission(initially: Bool) {
        setStatus(.noPermission)
        port.unregisterHotkeys()
        registered = []
        auditTimer?.cancel()
        if !initially {
            notify(Notice("permission-lost", .error, L10n.t(
                "Tessera ha perdido el permiso de Accesibilidad. Actívalo en Ajustes › Privacidad y seguridad › Accesibilidad.",
                "Tessera lost the Accessibility permission. Turn it on in System Settings › Privacy & Security › Accessibility."
            )))
        }
        permissionTimer?.cancel()
        permissionTimer = Repeater(interval: timing.permissionPoll) { [weak self] in self?.pollPermission() }
    }

    func pollPermission() {
        guard status == .noPermission, port.isTrusted(prompt: false) else { return }
        notify(Notice("permission-restored", .info, L10n.t("Permiso de Accesibilidad concedido: Tessera vuelve a ordenar las ventanas.",
                                                            "Accessibility permission granted: Tessera is tiling again.")))
        activate()
    }

    /// Three crashes in five minutes: restore every window and move nothing (plan §3).
    func enterSafeMode() {
        setStatus(.safeMode)
        log.error("crash loop detected (\(CrashGuard.limit) starts within \(Int(CrashGuard.window)) s): safe mode")
        notify(Notice("safe-mode", .error, L10n.t(
            "Tessera se ha cerrado varias veces seguidas. Modo seguro: ventanas restauradas, sin mosaico. Usa «Reintentar» en el menú.",
            "Tessera quit unexpectedly several times. Safe mode: windows restored, no tiling. Use “Retry” in the menu."
        )))
        if port.isTrusted(prompt: false) {
            refreshScreen(force: true)
            refreshSpaces()
            for app in port.runningApps() where isManaged(app) { adopt(app, scan: false) }
            restoreAll(timeout: timing.shutdownWait) {}
        }
    }

    func retryFromSafeMode() {
        guard status == .safeMode else { return }
        crashGuard.recordCleanExit()
        try? SecureFile.writeJSON(crashGuard, to: paths.starts)
        if port.isTrusted(prompt: options.promptForPermission) { activate() } else { enterNoPermission(initially: true) }
    }

    public func togglePause() {
        switch status {
        case .active:
            setStatus(.paused(.user))
            registerKeymap()
            notify(Notice("paused", .info, L10n.t("Tessera en pausa: las ventanas se quedan donde están.", "Tessera paused: windows stay where they are.")))
        case .paused:
            resume()
        default:
            break
        }
    }

    func resume() {
        guard case .paused = status else { return }
        setStatus(.active)
        requested.removeAll()
        backoff.removeAll()
        registerKeymap()
        rescueSweep(reason: "resume")
        rescanAll()
        notify(Notice("resumed", .info, L10n.t("Tessera reanudado.", "Tessera resumed.")))
        scheduleRender()
    }

    /// Other tilers and Stage Manager fight Tessera for the same windows: pause while they run
    /// and resume by itself when they stop (audit E7).
    func preflight() {
        let tilers = port.otherTilersRunning()
        let stageManager = port.stageManagerEnabled()
        switch status {
        case .active, .paused(.conflict), .paused(.stageManager):
            if !tilers.isEmpty {
                if status != .paused(.conflict(tilers)) {
                    setStatus(.paused(.conflict(tilers)))
                    registerKeymap()
                    notify(Notice("conflict", .warning, L10n.t(
                        "\(tilers.joined(separator: ", ")) está ordenando ventanas: Tessera se pausa para no pelear con él.",
                        "\(tilers.joined(separator: ", ")) is tiling windows: Tessera pauses so they do not fight."
                    )))
                }
            } else if stageManager {
                if status != .paused(.stageManager) {
                    setStatus(.paused(.stageManager))
                    registerKeymap()
                    notify(Notice("stage-manager", .warning, L10n.t(
                        "Stage Manager está activo: Tessera se pausa hasta que lo desactives.",
                        "Stage Manager is on: Tessera pauses until you turn it off."
                    )))
                }
            } else if case .paused = status {
                resume()
            }
        default:
            break
        }
        if port.edgeTilingEnabled(), warnedOnce.insert("edge-tiling").inserted {
            notify(Notice("edge-tiling", .warning, L10n.t(
                "El mosaico de macOS al arrastrar a los bordes está activo y puede pelear con Tessera: desactívalo en Ajustes › Escritorio y Dock.",
                "macOS's drag-to-edge tiling is on and can fight Tessera: turn it off in System Settings › Desktop & Dock."
            ), onScreen: false))
        }
        let extra = screens.count - 1
        if extra > 0, warnedOnce.insert("screens-\(extra)").inserted {
            notify(Notice("second-screen", .warning, L10n.t(
                "Hay \(extra + 1) pantallas: por ahora Tessera ordena solo la principal y no toca las demás.",
                "There are \(extra + 1) screens: for now Tessera tiles only the main one and leaves the others alone."
            )))
        }
    }

    // MARK: - Persistence

    func loadPersistentState() {
        let now = port.now()
        let boot = port.bootSessionID()
        switch Journal.load(from: paths.journal, bootSession: boot, now: now) {
        case .fresh(let fresh):
            journal = fresh
        case .loaded(let loaded):
            journal = loaded
            if !loaded.hidden.isEmpty { log.notice("journal lists \(loaded.hidden.count) windows a previous run left hidden", .journal) }
        case .staleBoot(let fresh):
            journal = fresh
            log.notice("journal from another boot discarded", .journal)
        case .quarantined(let fresh, let moved):
            journal = fresh
            log.error("journal unreadable, moved to \(moved?.path ?? "nowhere")", .journal)
            notify(Notice("journal-corrupt", .warning, L10n.t(
                "El registro de ventanas ocultas estaba dañado y se ha apartado. Si falta alguna ventana, usa «Reunir todas las ventanas».",
                "The hidden-window record was damaged and was set aside. If a window is missing, use “Gather all windows”."
            )))
        }
        factStore = load(FactStore.self, from: paths.facts) ?? FactStore()
        factStore.prune(now: now)
        edgeClampStore = load(EdgeClampStore.self, from: paths.edgeClamp) ?? EdgeClampStore()
        crashGuard = load(CrashGuard.self, from: paths.starts) ?? CrashGuard()
    }

    func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        do {
            return try SecureFile.readJSON(type, from: url)
        } catch {
            SecureFile.quarantine(url, now: port.now())
            log.error("\(url.lastPathComponent) unreadable, set aside")
            return nil
        }
    }

    func saveJournal() {
        guard !options.dryRun else { return }
        do {
            try journal.save(to: paths.journal)
            Metrics.count(.journalWrites)
        } catch {
            log.error("journal write failed: \(error)", .journal)
            notify(Notice("journal-write", .error, L10n.t(
                "No se pudo guardar el registro de ventanas ocultas: Tessera deja de ocultar ventanas hasta que se pueda.",
                "Could not save the hidden-window record: Tessera stops hiding windows until it can."
            )))
        }
    }

    /// Restores the trees saved by a previous run of this boot, for windows that still exist.
    func restoreWorldSnapshot() {
        guard let snapshot = load(WorldSnapshot.self, from: paths.world), snapshot.bootSession == port.bootSessionID() else { return }
        var restored = snapshot.world
        restored.settings = settings
        let presence = port.presence(of: Array(restored.windows.keys))
        for id in restored.windows.keys where !presence.existing.contains(id) {
            restored = Reducer.reduce(restored, .windowGone(id), area: tilingArea ?? Rect(x: 0, y: 0, width: 1, height: 1))
        }
        restored.focused = nil
        world = restored
        refreshSpaces()
        log.notice("restored \(world.windows.count) windows' places from the previous run")
    }

    func scheduleWorldSave() {
        guard !worldSaveScheduled, !options.dryRun else { return }
        worldSaveScheduled = true
        after(timing.worldSaveDebounce) { [weak self] in self?.flushWorldSnapshot() }
    }

    func flushWorldSnapshot() {
        worldSaveScheduled = false
        guard !options.dryRun, status != .safeMode else { return }
        try? SecureFile.writeJSON(WorldSnapshot(bootSession: port.bootSessionID(), world: world), to: paths.world)
    }

    // MARK: - Configuration

    var configURL: URL {
        options.configFile ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/tessera/tessera.local.toml")
    }

    /// Reads the local configuration overlay; errors are reported, never fatal (audit E9).
    func loadConfig(reporting: Bool) {
        configErrors = []
        var config = LocalConfig()
        if let text = try? String(contentsOf: configURL, encoding: .utf8) {
            do {
                config = try LocalConfig.parse(text)
                configErrors = config.warnings
            } catch {
                configErrors = [error.description]
            }
        }
        localConfig = config
        settings = config.applied(to: options.settings)
        world.settings = settings
        if !configErrors.isEmpty {
            log.error("configuration \(configURL.path): \(configErrors.joined(separator: "; "))")
            notify(Notice("config-error", .warning, L10n.t(
                "Configuración con errores (\(configErrors[0])); el resto se aplica.",
                "Configuration has errors (\(configErrors[0])); the rest applies."
            )))
        } else if reporting {
            notify(Notice("config-reloaded", .info, L10n.t("Configuración recargada.", "Configuration reloaded.")))
        }
    }

    /// Drops every learned minimum and maximum, here and in the store, and lays windows out again.
    public func forgetLearnedSizes() {
        for id in world.facts.keys { dispatch(.factsLearned(id, .flexible)) }
        factStore = FactStore()
        if !options.dryRun { try? SecureFile.writeJSON(factStore, to: paths.facts) }
        factCandidates.removeAll()
        contradictions.removeAll()
        requested.removeAll()
        backoff.removeAll()
        refusedTarget.removeAll()
        notify(Notice("sizes-forgotten", .info, L10n.t(
            "Tamaños aprendidos olvidados: Tessera vuelve a medir cada ventana.",
            "Learned sizes forgotten: Tessera measures every window again."
        )))
        scheduleRender()
    }

    public func reloadConfig() {
        loadConfig(reporting: true)
        registerKeymap()
        requested.removeAll()
        rescanAll()
        scheduleRender()
    }

    var nativeWorkspaces: Bool { localConfig.emulatedWorkspaces.map { !$0 } ?? options.nativeWorkspaces }

    // MARK: - UI

    public func perform(_ action: UIAction) {
        switch action {
        case .command(let command): execute(command)
        case .jumpToDesktop(let number): execute(.workspace(String(number)))
        case .togglePause: togglePause()
        case .gather: retileAll()
        case .revertLayout: revertToOriginalLayout()
        case .retry: retryFromSafeMode()
        case .reloadConfig: reloadConfig()
        case .forgetSizes: forgetLearnedSizes()
        case .quit: onQuitRequested?()
        }
    }

    func notify(_ notice: Notice) {
        noticeCounts[notice.key, default: 0] += 1
        activity.insert(ActivityEntry(at: port.now(), notice: notice), at: 0)
        if activity.count > 20 { activity.removeLast(activity.count - 20) }
        switch notice.kind {
        case .error: log.error("notice \(notice.key): \(notice.text)")
        case .warning, .info: log.info("notice \(notice.key): \(notice.text)")
        }
        ui.notify(notice)
        publishUI()
    }

    func publishUI() {
        var state = UIState()
        state.status = status
        state.nativeWorkspaces = nativeWorkspaces
        state.desktopNumber = desktopNumber()
        state.desktopCount = desktopOrder.count
        if let space = world.activeSpaceState, space.kind == .desktop {
            state.groups = space.workspaces.map { UIState.Group(name: $0.name, windows: $0.windows.count, isActive: $0.name == space.activeWorkspace) }
        }
        state.layout = world.activeWorkspace?.layout
        state.zoomed = world.activeWorkspace?.zoomed != nil
        state.canRevert = canRevert
        state.keymap = keymap
        state.activity = activity
        state.screensBeyondPrimary = max(0, screens.count - 1)
        guard state != lastUIState else { return }
        lastUIState = state
        ui.update(state)
    }

    // MARK: - Helpers

    /// Runs `body` on the main actor after `delay` seconds.
    func after(_ delay: TimeInterval, _ body: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { body() } }
    }

    /// Hops a driver completion back to the main actor.
    nonisolated func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
    }

    var primaryScreen: ScreenInfo? { screens.first }

    /// The area windows can really occupy: the usable area minus the learned edge clamp.
    var tilingArea: Rect? { primaryScreen.map { $0.usableArea.inset(by: edgeClamp.insets) } }

    func driver(for id: WindowID) -> (any AppDriver)? {
        world.windows[id].flatMap { drivers[$0.pid] }
    }

    func dispatch(_ event: Event) {
        let area = tilingArea ?? Rect(x: 0, y: 0, width: 1, height: 1)
        let next = Reducer.reduce(world, event, area: area)
        guard next != world else { return }
        log.debug("event \(event)")
        world = next
        scheduleWorldSave()
        scheduleRender()
    }

    /// Position of the active Space among desktop Spaces, as Mission Control numbers them.
    func desktopNumber() -> Int? {
        guard let active = world.activeSpace, world.spaces[active]?.kind == .desktop else { return nil }
        return desktopOrder.firstIndex(of: active).map { $0 + 1 } ?? (desktopOrder.isEmpty ? 1 : nil)
    }

    /// Model-level and screen-level invariants right now (`tessera debug check`, tests).
    public func checkInvariants() -> [String] {
        guard let area = tilingArea else { return [] }
        let render = Renderer.render(world, area: area)
        var result = Invariants.check(world, render: render, area: area).map(\.description)
        result += runtimeViolations(render: render).map(\.description)
        return result
    }
}

/// A token bucket: `rate` per second, up to `burst` at once (audit B4).
struct RateLimiter {
    let rate: Double
    let burst: Double
    var tokens: Double
    var last: Date?

    init(rate: Double, burst: Double) {
        self.rate = rate
        self.burst = burst
        tokens = burst
    }

    mutating func allow(now: Date) -> Bool {
        if let last { tokens = min(burst, tokens + now.timeIntervalSince(last) * rate) }
        last = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}
