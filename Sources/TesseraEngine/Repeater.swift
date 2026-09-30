import Foundation

/// A repeating timer on the main queue. Dispatch rather than `Timer`, so it fires the same way
/// in the app (run loop) and in tests (`dispatch_main`).
@MainActor
final class Repeater {
    private let source: any DispatchSourceTimer

    init(interval: TimeInterval, _ body: @escaping @MainActor @Sendable () -> Void) {
        source = DispatchSource.makeTimerSource(queue: .main)
        let leeway = DispatchTimeInterval.milliseconds(max(1, Int(interval * 250)))
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        source.setEventHandler { MainActor.assumeIsolated { body() } }
        source.resume()
    }

    func cancel() { source.cancel() }

    isolated deinit { source.cancel() }
}
