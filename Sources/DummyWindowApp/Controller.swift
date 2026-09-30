import AppKit
import DummyWindowKit
import TesseraCore

@MainActor
final class Controller {
    private var windows: [String: ConstrainedWindow] = [:]
    private var order: [String] = []

    func handle(_ request: Request) -> Response {
        switch request.op {
        case .open:
            guard let spec = request.spec else { return .failure("open needs a spec") }
            guard windows[spec.id] == nil else { return .failure("window '\(spec.id)' already exists") }
            let window = ConstrainedWindow(spec: spec)
            windows[spec.id] = window
            order.append(spec.id)
            window.orderFrontRegardless()
            if let selfResize = spec.selfResize { schedule(selfResize, for: spec.id) }
            return Response(ok: true, windows: [window.state])

        case .setFrame:
            guard let window = window(for: request.id) else { return .failure("unknown window") }
            guard let frame = request.frame else { return .failure("setFrame needs a frame") }
            window.setFrame(Coordinates.appKit(frame), display: true)
            return Response(ok: true, windows: [window.state])

        case .query:
            guard let window = window(for: request.id) else { return .failure("unknown window") }
            return Response(ok: true, windows: [window.state])

        case .list:
            return Response(ok: true, windows: order.compactMap { windows[$0]?.state })

        case .close:
            guard let id = request.id, let window = windows.removeValue(forKey: id) else {
                return .failure("unknown window")
            }
            order.removeAll { $0 == id }
            window.close()
            return Response(ok: true)

        case .quit:
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return Response(ok: true)
        }
    }

    private func window(for id: String?) -> ConstrainedWindow? {
        id.flatMap { windows[$0] }
    }

    private func schedule(_ selfResize: SelfResize, for id: String) {
        let delay = DispatchTimeInterval.milliseconds(selfResize.afterMilliseconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let window = self?.windows[id] else { return }
                var frame = window.frame
                frame.origin.y = frame.maxY - CGFloat(selfResize.size.height)
                frame.size = NSSize(width: selfResize.size.width, height: selfResize.size.height)
                window.performInternally { window.setFrame(frame, display: true) }
            }
        }
    }
}
