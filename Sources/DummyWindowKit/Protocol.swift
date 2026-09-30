public import TesseraCore

/// Wire protocol of `DummyWindowApp`: one JSON object per line over a Unix socket.
///
/// Example: `{"op":"open","spec":{"id":"a","frame":{"x":0,"y":30,"width":540,"height":800},"minSize":{"width":400,"height":300}}}`
public struct Request: Codable, Sendable, Equatable {
    public enum Operation: String, Codable, Sendable {
        case open, setFrame, query, list, close, quit
    }

    public var op: Operation
    public var id: String?
    public var spec: WindowSpec?
    public var frame: Rect?

    public init(op: Operation, id: String? = nil, spec: WindowSpec? = nil, frame: Rect? = nil) {
        self.op = op
        self.id = id
        self.spec = spec
        self.frame = frame
    }
}

public struct Response: Codable, Sendable, Equatable {
    public var ok: Bool
    public var error: String?
    public var windows: [WindowState]?

    public init(ok: Bool, error: String? = nil, windows: [WindowState]? = nil) {
        self.ok = ok
        self.error = error
        self.windows = windows
    }

    public static func failure(_ message: String) -> Response { Response(ok: false, error: message) }
}

public struct WindowState: Codable, Sendable, Equatable {
    public var id: String
    /// Global points, top-left origin, as the Accessibility API would report it.
    public var frame: Rect
    /// Equals the window's `CGWindowID`.
    public var windowNumber: Int

    public init(id: String, frame: Rect, windowNumber: Int) {
        self.id = id
        self.frame = frame
        self.windowNumber = windowNumber
    }
}

/// How a test window behaves when something outside the app changes its frame.
public struct WindowSpec: Codable, Sendable, Equatable {
    public var id: String
    /// Initial frame in global points, top-left origin.
    public var frame: Rect
    public var title: String?
    public var minSize: Size?
    public var maxSize: Size?
    /// Size increments, like a terminal's character grid. Anchored at `minSize` (or zero).
    public var quantum: Size?
    /// Width:height. The width drives and the height follows.
    public var aspectRatio: Size?
    /// When true, the window refuses every external frame change (models an app that ignores `setFrame`).
    public var rigid: Bool
    /// Resize itself once, some time after opening (models Electron restoring its state).
    public var selfResize: SelfResize?
    /// Whether the window offers native full screen, as ordinary app windows do. Without it,
    /// window managers classify the window as a dialog.
    public var fullScreenCapable: Bool

    public init(
        id: String, frame: Rect, title: String? = nil, minSize: Size? = nil, maxSize: Size? = nil,
        quantum: Size? = nil, aspectRatio: Size? = nil, rigid: Bool = false, selfResize: SelfResize? = nil,
        fullScreenCapable: Bool = true
    ) {
        self.id = id
        self.frame = frame
        self.title = title
        self.minSize = minSize
        self.maxSize = maxSize
        self.quantum = quantum
        self.aspectRatio = aspectRatio
        self.rigid = rigid
        self.selfResize = selfResize
        self.fullScreenCapable = fullScreenCapable
    }

    enum CodingKeys: String, CodingKey {
        case id, frame, title, minSize, maxSize, quantum, aspectRatio, rigid, selfResize, fullScreenCapable
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        frame = try container.decode(Rect.self, forKey: .frame)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        minSize = try container.decodeIfPresent(Size.self, forKey: .minSize)
        maxSize = try container.decodeIfPresent(Size.self, forKey: .maxSize)
        quantum = try container.decodeIfPresent(Size.self, forKey: .quantum)
        aspectRatio = try container.decodeIfPresent(Size.self, forKey: .aspectRatio)
        rigid = try container.decodeIfPresent(Bool.self, forKey: .rigid) ?? false
        selfResize = try container.decodeIfPresent(SelfResize.self, forKey: .selfResize)
        fullScreenCapable = try container.decodeIfPresent(Bool.self, forKey: .fullScreenCapable) ?? true
    }
}

public struct SelfResize: Codable, Sendable, Equatable {
    public var afterMilliseconds: Int
    public var size: Size

    public init(afterMilliseconds: Int, size: Size) {
        self.afterMilliseconds = afterMilliseconds
        self.size = size
    }
}
