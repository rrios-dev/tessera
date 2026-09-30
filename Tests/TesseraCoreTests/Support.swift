@testable import TesseraCore

/// Deterministic generator so every failing case can be replayed from its seed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct TreeGenerator {
    var rng: SplitMix64
    var nextID: WindowID = 1

    init(seed: UInt64) { rng = SplitMix64(seed: seed) }

    mutating func container(depth: Int, axis: AxisSpec = .primary) -> Container {
        let count = Int.random(in: 1...(depth == 0 ? 5 : 4), using: &rng)
        var children: [Node] = []
        for _ in 0..<count {
            if depth < 3 && Int.random(in: 0..<4, using: &rng) == 0 {
                children.append(.container(container(depth: depth + 1, axis: axis.flipped)))
            } else {
                children.append(.window(nextID))
                nextID += 1
            }
        }
        let shares = children.map { _ in Int.random(in: 1...10, using: &rng) }
        return Container(axis: axis, children: children, weights: Weights.applyingFloor(Weights.apportion(Weights.total, shares: shares)))
    }

    mutating func facts(for windows: [WindowID], strictness: Int) -> [WindowID: WindowFacts] {
        var result: [WindowID: WindowFacts] = [:]
        for id in windows where Int.random(in: 0..<4, using: &rng) < strictness {
            var fact = WindowFacts()
            if Bool.random(using: &rng) { fact.minSize = Size(width: Int.random(in: 50...420, using: &rng), height: Int.random(in: 50...320, using: &rng)) }
            if Int.random(in: 0..<3, using: &rng) == 0 { fact.maxSize = Size(width: Int.random(in: 500...1400, using: &rng), height: Int.random(in: 500...1600, using: &rng)) }
            if Int.random(in: 0..<3, using: &rng) == 0 { fact.quantum = Size(width: Int.random(in: 6...9, using: &rng), height: Int.random(in: 14...19, using: &rng)) }
            if let minimum = fact.minSize, let maximum = fact.maxSize {
                fact.maxSize = Size(width: max(minimum.width, maximum.width), height: max(minimum.height, maximum.height))
            }
            result[id] = fact
        }
        return result
    }
}

/// Areas from the plan's property matrix, including the owner's portrait monitor.
let testAreas: [Rect] = [
    Rect(x: 0, y: 30, width: 1080, height: 2448),
    Rect(x: 0, y: 30, width: 2560, height: 1018),
    Rect(x: 0, y: 25, width: 1440, height: 2535),
    Rect(x: 0, y: 25, width: 800, height: 575),
    Rect(x: -1440, y: 0, width: 5120, height: 1415),
    Rect(x: 1080, y: 0, width: 3840, height: 2135),
]

/// Area taken by inner gaps, walking the tree the same way the solver does.
func gapArea(_ container: Container, in rect: Rect, gap: Int, plan: Solver.Plan, primary: Axis) -> Int {
    let along = container.axis.resolve(primary: primary)
    let across = along == .horizontal ? rect.height : rect.width
    var total = gap * max(0, container.children.count - 1) * across
    for child in container.children {
        guard case .container(let nested) = child else { continue }
        let tiles = nested.windows.compactMap { plan.tiles[$0] }
        guard let first = tiles.first else { continue }
        let bounds = tiles.dropFirst().reduce(first) { acc, r in
            let x = min(acc.minX, r.minX), y = min(acc.minY, r.minY)
            return Rect(x: x, y: y, width: max(acc.maxX, r.maxX) - x, height: max(acc.maxY, r.maxY) - y)
        }
        total += gapArea(nested, in: bounds, gap: gap, plan: plan, primary: primary)
    }
    return total
}
