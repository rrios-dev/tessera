/// What Tessera has learned about how a window accepts sizes.
///
/// Facts are measured (a size was requested and a different one read back), never assumed;
/// until then the solver treats the window as fully flexible.
public struct WindowFacts: Codable, Sendable, Hashable {
    public var minSize: Size?
    public var maxSize: Size?
    /// Size increments (terminal grids), anchored at `minSize` or zero.
    public var quantum: Size?

    public init(minSize: Size? = nil, maxSize: Size? = nil, quantum: Size? = nil) {
        self.minSize = minSize
        self.maxSize = maxSize
        self.quantum = quantum
    }

    public static let flexible = WindowFacts()

    static let unbounded = 1 << 30

    func minimum(_ axis: Axis) -> Int { minSize.map { axis == .horizontal ? $0.width : $0.height } ?? 1 }
    func maximum(_ axis: Axis) -> Int { maxSize.map { axis == .horizontal ? $0.width : $0.height } ?? Self.unbounded }
    func step(_ axis: Axis) -> Int { quantum.map { axis == .horizontal ? $0.width : $0.height } ?? 1 }
}
