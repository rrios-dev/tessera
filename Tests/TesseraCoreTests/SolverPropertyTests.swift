import Testing
@testable import TesseraCore

struct SolverPropertyTests {
    static let seeds = 0..<4_000

    /// I1 + I2: when nothing overflows, tiles and gaps partition the area exactly.
    @Test func tilesPartitionTheAreaExactly() {
        var checked = 0
        for seed in Self.seeds {
            var generator = TreeGenerator(seed: UInt64(seed))
            let root = generator.container(depth: 0).normalized()
            let area = testAreas[seed % testAreas.count]
            let gap = [0, 0, 5, 10][seed % 4]
            let facts = generator.facts(for: root.windows, strictness: seed % 4)
            let plan = Solver.solve(root, in: area, facts: facts, options: .init(innerGap: gap))
            guard plan.overflowed == 0, plan.reflowed == 0 else { continue }
            checked += 1

            let tiles = root.windows.map { plan.tiles[$0]! }
            for tile in tiles {
                #expect(area.contains(tile), "seed \(seed): tile \(tile) outside \(area)")
            }
            for i in tiles.indices {
                for j in tiles.indices where j > i {
                    #expect(!tiles[i].intersects(tiles[j]), "seed \(seed): overlap \(tiles[i]) \(tiles[j])")
                }
            }
            let covered = tiles.reduce(0) { $0 + $1.area }
            let gaps = gapArea(root, in: area, gap: gap, plan: plan, primary: Solver.primaryAxis(for: area))
            #expect(covered + gaps == area.area, "seed \(seed): covered \(covered) + gaps \(gaps) != \(area.area)")
        }
        #expect(checked > 2_000, "too few non-overflowing cases: \(checked)")
    }

    /// I3 + I1b: every frame fits its tile when the tile is big enough, respects the window's
    /// minimum and maximum, and leaves at most one grid step of slack per axis.
    @Test func framesRespectFactsAndStayInsideTiles() {
        for seed in Self.seeds {
            var generator = TreeGenerator(seed: UInt64(seed) &+ 99_991)
            let root = generator.container(depth: 0).normalized()
            let area = testAreas[seed % testAreas.count]
            let facts = generator.facts(for: root.windows, strictness: 3)
            let plan = Solver.solve(root, in: area, facts: facts)
            guard plan.overflowed == 0 else { continue }

            for id in root.windows {
                let tile = plan.tiles[id]!
                let frame = plan.frames[id]!
                let fact = facts[id] ?? .flexible
                #expect(frame.origin == tile.origin)
                if let minimum = fact.minSize {
                    #expect(frame.width >= minimum.width && frame.height >= minimum.height, "seed \(seed) window \(id)")
                }
                let fitsWidth = tile.width >= (fact.minSize?.width ?? 0)
                let fitsHeight = tile.height >= (fact.minSize?.height ?? 0)
                if fitsWidth { #expect(frame.width <= tile.width, "seed \(seed) window \(id) wider than tile") }
                if fitsHeight { #expect(frame.height <= tile.height, "seed \(seed) window \(id) taller than tile") }
                if let maximum = fact.maxSize {
                    #expect(frame.width <= max(maximum.width, fact.minSize?.width ?? 0))
                    #expect(frame.height <= max(maximum.height, fact.minSize?.height ?? 0))
                }
                if let quantum = fact.quantum, fact.maxSize == nil, fitsWidth, fitsHeight {
                    #expect(tile.width - frame.width < quantum.width, "seed \(seed): slack \(tile.width - frame.width) ≥ \(quantum.width)")
                    #expect(tile.height - frame.height < quantum.height, "seed \(seed): slack \(tile.height - frame.height) ≥ \(quantum.height)")
                }
            }
        }
    }

    /// I6: the same input always yields the same plan.
    /// Reflowing never overlaps and never leaves holes: whatever reflows still partitions the area.
    @Test func reflowedLayoutsStillPartitionTheArea() {
        var reflowedCases = 0
        for seed in 0..<20_000 {
            var generator = TreeGenerator(seed: UInt64(seed) &+ 7_777)
            let root = generator.container(depth: 0).normalized()
            let area = testAreas[seed % testAreas.count]
            let facts = generator.facts(for: root.windows, strictness: 3)
            let plan = Solver.solve(root, in: area, facts: facts)
            guard plan.reflowed > 0, plan.overflowed == 0 else { continue }
            reflowedCases += 1
            let tiles = root.windows.map { plan.tiles[$0]! }
            for i in tiles.indices {
                #expect(area.contains(tiles[i]), "seed \(seed)")
                for j in tiles.indices where j > i { #expect(!tiles[i].intersects(tiles[j]), "seed \(seed)") }
            }
            #expect(tiles.reduce(0) { $0 + $1.area } == area.area, "seed \(seed)")
        }
        #expect(reflowedCases > 50, "too few reflowed cases: \(reflowedCases)")
    }

    @Test func solvingIsDeterministic() {
        for seed in 0..<500 {
            var generator = TreeGenerator(seed: UInt64(seed))
            let root = generator.container(depth: 0)
            let facts = generator.facts(for: root.windows, strictness: 2)
            let area = testAreas[seed % testAreas.count]
            #expect(Solver.solve(root, in: area, facts: facts) == Solver.solve(root, in: area, facts: facts))
        }
    }

    /// I4: moving a workspace to a portrait monitor and back reproduces the frames exactly.
    @Test func orientationRoundTripIsExact() {
        let landscape = Rect(x: 0, y: 30, width: 2560, height: 1018)
        let portrait = Rect(x: 0, y: 30, width: 1080, height: 2448)
        for seed in 0..<500 {
            var generator = TreeGenerator(seed: UInt64(seed))
            let root = generator.container(depth: 0)
            let before = Solver.solve(root, in: landscape, facts: [:])
            _ = Solver.solve(root, in: portrait, facts: [:])
            #expect(Solver.solve(root, in: landscape, facts: [:]) == before)
        }
    }

    @Test func portraitAreaStacksTheRootVertically() {
        let root = Container(children: [.window(1), .window(2)])
        let plan = Solver.solve(root, in: Rect(x: 0, y: 30, width: 1080, height: 2448), facts: [:])
        #expect(plan.tiles[1] == Rect(x: 0, y: 30, width: 1080, height: 1224))
        #expect(plan.tiles[2] == Rect(x: 0, y: 1254, width: 1080, height: 1224))
    }

    @Test func minimumWidthIsHonouredOnANarrowColumn() {
        // Two columns inside a portrait monitor: the right one needs 700 points.
        let row = Container(axis: .secondary, children: [.window(1), .window(2)])
        let root = Container(children: [.container(row)])
        let facts: [WindowID: WindowFacts] = [2: WindowFacts(minSize: Size(width: 700, height: 300))]
        let plan = Solver.solve(root.normalized(), in: Rect(x: 0, y: 30, width: 1080, height: 2448), facts: facts)
        #expect(plan.tiles[2]!.width == 700)
        #expect(plan.tiles[1]!.width == 380)
        #expect(plan.overflowed == 0)
    }

    /// Measured on the owner's Mac: two real apps needing 623 and 500 points of width cannot sit
    /// side by side on a 1080-wide portrait monitor. They stack instead of overlapping.
    @Test func sideBySideThatDoesNotFitIsStacked() {
        let root = Container(axis: .fixed(.horizontal), children: [.window(1), .window(2)])
        let facts: [WindowID: WindowFacts] = [
            1: WindowFacts(minSize: Size(width: 623, height: 0)),
            2: WindowFacts(minSize: Size(width: 500, height: 0)),
        ]
        let area = Rect(x: 0, y: 30, width: 1080, height: 2447)
        let plan = Solver.solve(root, in: area, facts: facts)
        #expect(plan.reflowed == 1)
        #expect(plan.overflowed == 0)
        #expect(plan.tiles[1] == Rect(x: 0, y: 30, width: 1080, height: 1224))
        #expect(plan.tiles[2] == Rect(x: 0, y: 1254, width: 1080, height: 1223))
        // On a landscape monitor the same tree goes back to side by side.
        let wide = Solver.solve(root, in: Rect(x: 0, y: 30, width: 2560, height: 1018), facts: facts)
        #expect(wide.reflowed == 0)
        #expect(wide.tiles[1]!.height == 1018 && wide.tiles[2]!.height == 1018)
    }

    @Test func overflowFallsBackToAccordionInsteadOfLeavingHoles() {
        let root = Container(axis: .fixed(.horizontal), children: [.window(1), .window(2)])
        let facts: [WindowID: WindowFacts] = [
            1: WindowFacts(minSize: Size(width: 700, height: 1300)),
            2: WindowFacts(minSize: Size(width: 700, height: 1300)),
        ]
        let area = Rect(x: 0, y: 30, width: 1080, height: 2448)
        let plan = Solver.solve(root, in: area, facts: facts, focusOrder: [2])
        #expect(plan.overflowed == 1)
        #expect(plan.stacking.first == 2)
        for id in [WindowID(1), 2] { #expect(area.contains(plan.tiles[id]!)) }
    }

    @Test func flexNeverLosesAPoint() {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<200_000 {
            let count = Int.random(in: 1...6, using: &rng)
            let weights = Weights.apportion(Weights.total, shares: (0..<count).map { _ in Int.random(in: 1...9, using: &rng) })
            let mins = (0..<count).map { _ in Int.random(in: 0...300, using: &rng) }
            let maxs = mins.map { $0 + Int.random(in: 0...2_000, using: &rng) }
            let lower = mins.reduce(0, +), upper = maxs.reduce(0, +)
            guard lower <= upper else { continue }
            let available = Int.random(in: lower...upper, using: &rng)
            let sizes = Solver.flex(available: available, weights: weights, mins: mins, maxs: maxs)
            #expect(sizes.reduce(0, +) == available)
            for index in sizes.indices { #expect(sizes[index] >= mins[index] && sizes[index] <= maxs[index]) }
        }
    }
}
