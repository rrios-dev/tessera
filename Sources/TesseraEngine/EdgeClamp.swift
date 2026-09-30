import TesseraCore

/// macOS keeps windows a point or two away from some outer edges of the usable area (with the
/// Dock at the bottom, a window can reach 1 point short of it). AeroSpace hard-codes
/// `height - 1`; Tessera measures it instead (plan §4.2, spike S2, ADR 0002).
///
/// A shortfall is blamed on the screen only when windows of two different apps stop the same
/// 1–3 points short at the same edge with the opposite edge in place (audit C4): a single app
/// that snaps to a character grid must not shrink the area for everyone. The total is capped at
/// `maximum` points per edge.
struct EdgeClamp: Equatable {
    private(set) var insets = Insets.zero
    /// Per edge: the total inset being proposed and the apps that reported it.
    private var pending: [Edge: (total: Int, pids: Set<Int32>)] = [:]

    static let maximum = 3

    enum Edge: Hashable { case top, left, bottom, right }

    enum Outcome: Equatable { case none, suspected, learned }

    init(insets: Insets = .zero) {
        self.insets = Insets(
            top: min(max(insets.top, 0), Self.maximum), left: min(max(insets.left, 0), Self.maximum),
            bottom: min(max(insets.bottom, 0), Self.maximum), right: min(max(insets.right, 0), Self.maximum)
        )
    }

    static func == (lhs: EdgeClamp, rhs: EdgeClamp) -> Bool { lhs.insets == rhs.insets }

    /// `.learned` when the clamp changed and the layout must be recomputed; `.suspected` when a
    /// shortfall needs confirmation from another app.
    mutating func observe(target: Rect, result: Rect, current: Rect, pid: Int32) -> Outcome {
        var changed = false
        var suspected = false
        func consider(_ edge: Edge, targetEdge: Int, resultEdge: Int, areaEdge: Int, anchored: Bool, sign: Int) {
            guard targetEdge == areaEdge, anchored else { return }
            let shortfall = (targetEdge - resultEdge) * sign
            guard (1...Self.maximum).contains(shortfall) else { return }
            let total = shortfall + currentInset(edge)
            guard total <= Self.maximum else { return }
            var entry: (total: Int, pids: Set<Int32>) = pending[edge].flatMap { $0.total == total ? $0 : nil } ?? (total: total, pids: [])
            entry.pids.insert(pid)
            if entry.pids.count >= 2 {
                set(edge, total)
                pending[edge] = nil
                changed = true
            } else {
                pending[edge] = entry
                suspected = true
            }
        }
        consider(.bottom, targetEdge: target.maxY, resultEdge: result.maxY, areaEdge: current.maxY, anchored: result.minY == target.minY, sign: 1)
        consider(.right, targetEdge: target.maxX, resultEdge: result.maxX, areaEdge: current.maxX, anchored: result.minX == target.minX, sign: 1)
        consider(.top, targetEdge: target.minY, resultEdge: result.minY, areaEdge: current.minY, anchored: result.maxY == target.maxY, sign: -1)
        consider(.left, targetEdge: target.minX, resultEdge: result.minX, areaEdge: current.minX, anchored: result.maxX == target.maxX, sign: -1)
        return changed ? .learned : suspected ? .suspected : .none
    }

    private func currentInset(_ edge: Edge) -> Int {
        switch edge {
        case .top: insets.top
        case .left: insets.left
        case .bottom: insets.bottom
        case .right: insets.right
        }
    }

    private mutating func set(_ edge: Edge, _ value: Int) {
        switch edge {
        case .top: insets.top = value
        case .left: insets.left = value
        case .bottom: insets.bottom = value
        case .right: insets.right = value
        }
    }
}
