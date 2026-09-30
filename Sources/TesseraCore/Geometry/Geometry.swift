/// Integer geometry in global points with a top-left origin.
///
/// This is the coordinate space of CoreGraphics (`CGDisplayBounds`, `kCGWindowBounds`)
/// and of the Accessibility API (`kAXPositionAttribute`). AppKit's bottom-left space is
/// converted at the platform boundary and never enters the core.
public struct Point: Hashable, Codable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(x: 0, y: 0)
}

public struct Size: Hashable, Codable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let zero = Size(width: 0, height: 0)
}

public struct Rect: Hashable, Codable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(origin: Point, size: Size) {
        self.init(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public var origin: Point { Point(x: x, y: y) }
    public var size: Size { Size(width: width, height: height) }
    public var minX: Int { x }
    public var minY: Int { y }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var area: Int { isEmpty ? 0 : width * height }

    /// Half-open containment: the right and bottom edges are outside the rect.
    public func contains(_ point: Point) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }

    public func contains(_ other: Rect) -> Bool {
        other.minX >= minX && other.maxX <= maxX && other.minY >= minY && other.maxY <= maxY
    }

    /// The overlapping region, or `nil` when the rects share no area.
    public func intersection(_ other: Rect) -> Rect? {
        let left = max(minX, other.minX)
        let top = max(minY, other.minY)
        let right = min(maxX, other.maxX)
        let bottom = min(maxY, other.maxY)
        guard right > left, bottom > top else { return nil }
        return Rect(x: left, y: top, width: right - left, height: bottom - top)
    }

    public func intersects(_ other: Rect) -> Bool { intersection(other) != nil }

    public func inset(by insets: Insets) -> Rect {
        Rect(
            x: x + insets.left,
            y: y + insets.top,
            width: width - insets.left - insets.right,
            height: height - insets.top - insets.bottom
        )
    }
}

public struct Insets: Hashable, Codable, Sendable {
    public var top: Int
    public var left: Int
    public var bottom: Int
    public var right: Int

    public init(top: Int, left: Int, bottom: Int, right: Int) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let zero = Insets(top: 0, left: 0, bottom: 0, right: 0)
}
