/// Turns a tiling tree into frames for one area, in integer points.
///
/// The algorithm is the one corrected in the round-4 audit (plan §4.2), where the previous
/// version broke the partition invariant on random trees:
///
/// 1. Measure bottom-up: along a container's axis `min = Σmin + gaps`, `max = Σmax + gaps`;
///    across it `min = max(minᵢ)`, `max = min(maxᵢ)`. Leaf minimums round up and maximums
///    round down onto the window's size grid.
/// 2. Distribute top-down with the CSS "resolve flexible lengths" loop in integers: each
///    pass apportions the free space by weight with the largest-remainder method, then
///    freezes every child that violates its bounds on the dominant side. At most n passes;
///    the sum is exact by construction, so no re-clamping afterwards.
/// 3. A tile is never smaller than the space it was given: when a window cannot fill its
///    tile (grid snapping, a maximum), the difference stays inside the tile as declared slack.
/// 4. When the minimums do not fit (overflow) the container is drawn as an accordion.
///    When the maximums cannot fill it (underfill) the free space goes to the far edge.
public enum Solver {
    public struct Options: Sendable, Hashable {
        public var innerGap: Int
        public var accordionPadding: Int
        public var overflow: OverflowPolicy

        public init(innerGap: Int = 0, accordionPadding: Int = 30, overflow: OverflowPolicy = .accordion) {
            self.innerGap = innerGap
            self.accordionPadding = accordionPadding
            self.overflow = overflow
        }
    }

    public struct Plan: Sendable, Equatable {
        /// The rectangle each window owns in the partition.
        public var tiles: [WindowID: Rect] = [:]
        /// Where each window should actually be: its tile, shrunk to the sizes it accepts.
        public var frames: [WindowID: Rect] = [:]
        /// Containers whose minimums did not fit either way (drawn by the overflow policy).
        public var overflowed = 0
        /// Of those, containers drawn stacked (every window over the whole container).
        public var stacked = 0
        /// Containers whose minimums did not fit along their axis but did across it, so they were
        /// drawn along the other axis (the tree is not changed; a wider area restores them).
        public var reflowed = 0
        /// Containers whose maximums could not fill the space they were given.
        public var underfilled = 0
        /// Front-to-back order for windows that overlap by design (accordion, monocle).
        public var stacking: [WindowID] = []

        public init() {}
    }

    public static func primaryAxis(for area: Rect) -> Axis {
        area.width >= area.height ? .horizontal : .vertical
    }

    /// - Parameter focusPath: windows in most-recently-focused order; decides which window of
    ///   an accordion is fully visible.
    public static func solve(
        _ root: Container,
        in area: Rect,
        facts: [WindowID: WindowFacts],
        focusOrder: [WindowID] = [],
        options: Options = Options()
    ) -> Plan {
        var plan = Plan()
        let context = Context(primary: primaryAxis(for: area), facts: facts, focusOrder: focusOrder, options: options, bounds: area)
        guard !root.isEmpty else { return plan }
        context.layout(.container(root), in: area, plan: &plan)
        plan.stacking = context.stacking(of: root.windows)
        return plan
    }

    /// Every window gets the whole area; the most recently focused is in front.
    public static func solveMonocle(windows: [WindowID], in area: Rect, facts: [WindowID: WindowFacts], focusOrder: [WindowID]) -> Plan {
        var plan = Plan()
        let context = Context(primary: primaryAxis(for: area), facts: facts, focusOrder: focusOrder, options: Options(), bounds: area)
        for id in windows {
            plan.tiles[id] = area
            plan.frames[id] = context.frame(for: id, in: area)
        }
        plan.stacking = context.stacking(of: windows)
        return plan
    }

    struct Bounds {
        var minimum: [Axis: Int]
        var maximum: [Axis: Int]
    }

    struct Context {
        let primary: Axis
        let facts: [WindowID: WindowFacts]
        let focusOrder: [WindowID]
        let options: Options
        /// The whole area being solved: frames larger than their tile are kept inside it.
        let bounds: Rect

        func stacking(of windows: [WindowID]) -> [WindowID] {
            let rank = Dictionary(focusOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            return windows.enumerated().sorted { lhs, rhs in
                let left = rank[lhs.element] ?? Int.max
                let right = rank[rhs.element] ?? Int.max
                return left != right ? left < right : lhs.offset < rhs.offset
            }.map(\.element)
        }

        // MARK: Measure

        func bounds(_ node: Node) -> Bounds {
            switch node {
            case .window(let id):
                let fact = facts[id] ?? .flexible
                var minimum: [Axis: Int] = [:]
                var maximum: [Axis: Int] = [:]
                for axis in [Axis.horizontal, .vertical] {
                    let base = fact.minSize.map { axis == .horizontal ? $0.width : $0.height } ?? 0
                    let step = fact.step(axis)
                    minimum[axis] = snapUp(fact.minimum(axis), base: base, step: step)
                    maximum[axis] = max(minimum[axis]!, snapDown(fact.maximum(axis), base: base, step: step))
                }
                return Bounds(minimum: minimum, maximum: maximum)

            case .container(let container):
                let along = container.axis.resolve(primary: primary)
                let across = along.opposite
                let childBounds = container.children.map(bounds)
                let gaps = options.innerGap * max(0, childBounds.count - 1)
                var minimum: [Axis: Int] = [:]
                var maximum: [Axis: Int] = [:]
                if container.kind == .accordion {
                    let padding = options.accordionPadding * min(2, max(0, childBounds.count - 1))
                    minimum[along] = (childBounds.map { $0.minimum[along]! }.max() ?? 0) + padding
                    maximum[along] = WindowFacts.unbounded
                } else {
                    minimum[along] = childBounds.reduce(gaps) { $0 + $1.minimum[along]! }
                    maximum[along] = min(WindowFacts.unbounded, childBounds.reduce(gaps) { $0 + $1.maximum[along]! })
                }
                minimum[across] = childBounds.map { $0.minimum[across]! }.max() ?? 0
                maximum[across] = max(minimum[across]!, childBounds.map { $0.maximum[across]! }.min() ?? WindowFacts.unbounded)
                return Bounds(minimum: minimum, maximum: maximum)
            }
        }

        // MARK: Distribute

        func layout(_ node: Node, in rect: Rect, plan: inout Plan) {
            switch node {
            case .window(let id):
                plan.tiles[id] = rect
                plan.frames[id] = frame(for: id, in: rect)

            case .container(let container):
                let along = container.axis.resolve(primary: primary)
                let childBounds = container.children.map(bounds)
                let mins = childBounds.map { $0.minimum[along]! }
                let maxs = childBounds.map { $0.maximum[along]! }
                let gaps = options.innerGap * max(0, container.children.count - 1)
                let available = length(rect, along) - gaps

                if container.kind == .tiles, mins.reduce(0, +) > available, fitsAcross(container, along: along, in: rect) {
                    // Side by side does not fit (two wide apps on a portrait monitor) but stacked
                    // does: draw this container along the other axis rather than overlap windows.
                    plan.reflowed += 1
                    var flipped = container
                    flipped.axis = .fixed(along.opposite)
                    layout(.container(flipped), in: rect, plan: &plan)
                    return
                }
                if container.kind == .accordion {
                    layoutAccordion(container, along: along, in: rect, plan: &plan)
                    return
                }
                if mins.reduce(0, +) > available {
                    plan.overflowed += 1
                    switch options.overflow {
                    case .accordion where container.children.count <= OverflowPolicy.maxAccordionStrips, .floatLargest:
                        // floatLargest is resolved by the renderer, which takes windows out until
                        // the rest fits; whatever still overflows is drawn as an accordion.
                        layoutAccordion(container, along: along, in: rect, plan: &plan)
                    case .accordion, .stack:
                        plan.stacked += 1
                        for child in container.children { layout(child, in: rect, plan: &plan) }
                    case .allow:
                        var cursor = start(rect, along)
                        for (child, size) in zip(container.children, mins) {
                            layout(child, in: slice(rect, along: along, from: cursor, length: size), plan: &plan)
                            cursor += size + options.innerGap
                        }
                    }
                    return
                }

                var sizes = flex(available: available, weights: container.weights, mins: mins, maxs: maxs)
                let used = sizes.reduce(0, +)
                if used < available {
                    // Underfill: every child is at its maximum. The last tile absorbs the rest so the
                    // partition stays exact; its window stops at its maximum inside the tile.
                    plan.underfilled += 1
                    sizes[sizes.count - 1] += available - used
                }

                var cursor = start(rect, along)
                for (child, size) in zip(container.children, sizes) {
                    let childRect = slice(rect, along: along, from: cursor, length: size)
                    layout(child, in: childRect, plan: &plan)
                    cursor += size + options.innerGap
                }
            }
        }

        /// Whether the container's children fit when laid out along the other axis.
        func fitsAcross(_ container: Container, along: Axis, in rect: Rect) -> Bool {
            let across = along.opposite
            let childBounds = container.children.map(bounds)
            let gaps = options.innerGap * max(0, childBounds.count - 1)
            let needed = childBounds.reduce(gaps) { $0 + $1.minimum[across]! }
            let widest = childBounds.map { $0.minimum[along]! }.max() ?? 0
            return needed <= length(rect, across) && widest <= length(rect, along)
        }

        func layoutAccordion(_ container: Container, along: Axis, in rect: Rect, plan: inout Plan) {
            let windows = container.windows
            let focused = stacking(of: windows).first
            let focusedIndex = container.children.firstIndex { focused.map($0.contains) ?? false } ?? 0
            let count = container.children.count
            let padding = count > 1 ? options.accordionPadding : 0
            let total = length(rect, along)
            let origin = start(rect, along)

            for (index, child) in container.children.enumerated() {
                let leading = index > 0 && index >= focusedIndex ? padding : 0
                let trailing = index < count - 1 && index <= focusedIndex ? padding : 0
                let childRect = slice(rect, along: along, from: origin + leading, length: max(1, total - leading - trailing))
                layout(child, in: childRect, plan: &plan)
            }
        }

        /// The frame a window can actually take inside its tile: clamped to its maximum, snapped
        /// down to its grid, anchored at the tile's top-left. Never smaller than its minimum.
        func frame(for id: WindowID, in tile: Rect) -> Rect {
            let fact = facts[id] ?? .flexible
            var size = tile.size
            for axis in [Axis.horizontal, .vertical] {
                let base = fact.minSize.map { axis == .horizontal ? $0.width : $0.height } ?? 0
                var value = axis == .horizontal ? size.width : size.height
                value = min(value, fact.maximum(axis))
                value = snapDown(value, base: base, step: fact.step(axis))
                value = max(value, fact.minimum(axis))
                if axis == .horizontal { size.width = value } else { size.height = value }
            }
            var origin = tile.origin
            // A window whose minimum exceeds its tile would stick out of the area: shift it back
            // inside, keeping the tile's leading edge when it is wider than the whole area.
            if bounds.contains(tile) {
                if origin.x + size.width > bounds.maxX { origin.x = max(bounds.minX, bounds.maxX - size.width) }
                if origin.y + size.height > bounds.maxY { origin.y = max(bounds.minY, bounds.maxY - size.height) }
            }
            return Rect(origin: origin, size: size)
        }
    }

    /// CSS "resolve flexible lengths" in integers. Requires Σmins ≤ available.
    static func flex(available: Int, weights: [Int], mins: [Int], maxs: [Int]) -> [Int] {
        let count = weights.count
        var sizes = [Int](repeating: 0, count: count)
        var frozen = [Bool](repeating: false, count: count)

        for _ in 0...count {
            let open = (0..<count).filter { !frozen[$0] }
            if open.isEmpty { break }
            let remaining = available - (0..<count).filter { frozen[$0] }.reduce(0) { $0 + sizes[$1] }
            let tentative = Weights.apportion(max(0, remaining), shares: open.map { weights[$0] })

            var violation = 0
            var clamped: [Int: Int] = [:]
            for (slot, index) in open.enumerated() {
                let value = min(max(tentative[slot], mins[index]), maxs[index])
                clamped[index] = value
                violation += value - tentative[slot]
            }
            if violation == 0 {
                // Violations may cancel out (+65 at one child, −65 at another): the clamped
                // values are the answer and still sum to `remaining`.
                for index in open { sizes[index] = clamped[index]! }
                break
            }
            for (slot, index) in open.enumerated() {
                let value = clamped[index]!
                if (violation > 0 && value > tentative[slot]) || (violation < 0 && value < tentative[slot]) {
                    sizes[index] = value
                    frozen[index] = true
                }
            }
            if (0..<count).allSatisfy({ frozen[$0] }) { break }
        }
        return sizes
    }

    static func snapDown(_ value: Int, base: Int, step: Int) -> Int {
        guard step > 1, value > base else { return value }
        return base + ((value - base) / step) * step
    }

    static func snapUp(_ value: Int, base: Int, step: Int) -> Int {
        guard step > 1, value > base else { return value }
        let offset = value - base
        return base + ((offset + step - 1) / step) * step
    }

    static func length(_ rect: Rect, _ axis: Axis) -> Int { axis == .horizontal ? rect.width : rect.height }
    static func start(_ rect: Rect, _ axis: Axis) -> Int { axis == .horizontal ? rect.x : rect.y }

    static func slice(_ rect: Rect, along axis: Axis, from start: Int, length: Int) -> Rect {
        axis == .horizontal
            ? Rect(x: start, y: rect.y, width: length, height: rect.height)
            : Rect(x: rect.x, y: start, width: rect.width, height: length)
    }
}

extension Solver.Context {
    func length(_ rect: Rect, _ axis: Axis) -> Int { Solver.length(rect, axis) }
    func start(_ rect: Rect, _ axis: Axis) -> Int { Solver.start(rect, axis) }
    func slice(_ rect: Rect, along axis: Axis, from start: Int, length: Int) -> Rect {
        Solver.slice(rect, along: axis, from: start, length: length)
    }
    func flex(available: Int, weights: [Int], mins: [Int], maxs: [Int]) -> [Int] {
        Solver.flex(available: available, weights: weights, mins: mins, maxs: maxs)
    }
    func snapUp(_ value: Int, base: Int, step: Int) -> Int { Solver.snapUp(value, base: base, step: step) }
    func snapDown(_ value: Int, base: Int, step: Int) -> Int { Solver.snapDown(value, base: base, step: step) }
}
