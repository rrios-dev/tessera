import Testing
@testable import TesseraCore

/// Seeded random event sequences, every invariant checked after every event (plan §12: the
/// nightly run does 10⁶ steps through `tessera-bench model`; the unit suite does a slice).
struct ModelBasedReducerTests {
    static let areas = [
        Rect(x: 0, y: 30, width: 1080, height: 2447),
        Rect(x: 0, y: 25, width: 2560, height: 1415),
        Rect(x: 0, y: 25, width: 1512, height: 957),
    ]

    struct Generator {
        var rng: SplitMix64
        let spaces: [SpaceDescriptor] = [
            SpaceDescriptor(id: 3, kind: .desktop), SpaceDescriptor(id: 7, kind: .desktop), SpaceDescriptor(id: 90, kind: .fullscreen),
        ]
        var nextWindow: WindowID = 1

        init(seed: UInt64) { rng = SplitMix64(seed: seed) }

        mutating func pick<T>(_ values: [T]) -> T { values[Int.random(in: 0..<values.count, using: &rng)] }

        mutating func event(in world: World) -> Event {
            let known = Array(world.windows.keys).sorted()
            let roll = Int.random(in: 0..<100, using: &rng)
            switch roll {
            case 0..<18:
                let id = nextWindow
                nextWindow += 1
                return .windowObserved(WindowObservation(
                    id: id, pid: Int32.random(in: 100...104, using: &rng), space: pick([3, 3, 7, 90, nil]),
                    isNativeFullscreen: Int.random(in: 0..<20, using: &rng) == 0,
                    prefersFloating: Int.random(in: 0..<6, using: &rng) == 0,
                    isOnAllSpaces: Int.random(in: 0..<25, using: &rng) == 0
                ))
            case 18..<28 where !known.isEmpty:
                let id = pick(known)
                return .windowObserved(WindowObservation(
                    id: id, pid: world.windows[id]!.pid, space: pick([world.windows[id]!.space, 3, 7]),
                    isMinimized: Int.random(in: 0..<3, using: &rng) == 0,
                    isAppHidden: Int.random(in: 0..<5, using: &rng) == 0,
                    prefersFloating: Int.random(in: 0..<6, using: &rng) == 0
                ))
            case 28..<38 where !known.isEmpty:
                return .windowGone(pick(known))
            case 38..<48:
                return .focusChanged(known.isEmpty ? nil : pick(known))
            case 48..<53:
                return .spacesChanged(spaces, active: pick([3, 7, 90]))
            case 53..<58 where !known.isEmpty:
                let width = Int.random(in: 200...1800, using: &rng)
                return .factsLearned(pick(known), WindowFacts(minSize: Size(width: width, height: Int.random(in: 100...900, using: &rng))))
            default:
                return .command(command(known))
            }
        }

        mutating func command(_ known: [WindowID]) -> Command {
            switch Int.random(in: 0..<16, using: &rng) {
            case 0: return .focus(pick(Direction.allCases))
            case 1: return .move(pick(Direction.allCases))
            case 2: return .workspace(pick(["1", "2", "3", "web"]))
            case 3: return .workspaceBackAndForth
            case 4: return .moveNodeToWorkspace(pick(["1", "2", "3"]))
            case 5: return .layout(pick(LayoutMode.allCases))
            case 6: return .toggleOrientation
            case 7: return .toggleFloating
            case 8: return .toggleFullscreen
            case 9: return .balanceSizes
            case 10: return .resize(pick([.width, .height]), points: pick([-50, 50, 400, -Int.max, Int.max]))
            case 11 where known.count > 1: return .swapWindows(pick(known), pick(known))
            case 12 where !known.isEmpty:
                return .resizeWindow(pick(known), to: Rect(x: 0, y: 30, width: Int.random(in: 1...3000, using: &rng), height: Int.random(in: 1...3000, using: &rng)))
            case 13 where !known.isEmpty: return pick([.focusWindow(pick(known)), .setFloating(pick(known), Bool.random(using: &rng))])
            case 14 where known.count > 1: return .insertWindow(pick(known), beside: pick(known), after: Bool.random(using: &rng))
            default: return .balanceSizes
            }
        }
    }

    @Test(arguments: 0..<24)
    func randomEventSequencesKeepEveryInvariant(seed: UInt64) {
        var generator = Generator(seed: seed)
        let area = Self.areas[Int(seed) % Self.areas.count]
        var world = World(settings: WorldSettings(overflow: OverflowPolicy.allCases[Int(seed) % 4]))
        world = Reducer.reduce(world, .spacesChanged(generator.spaces, active: 3), area: area)
        for step in 0..<400 {
            let event = generator.event(in: world)
            let next = Reducer.reduce(world, event, area: area)
            // I6: determinism.
            #expect(Reducer.reduce(world, event, area: area) == next)
            // I5b: only resizes, drags, balancing and tree edits change weights.
            if case .focusChanged = event { #expect(sameWeights(next, world), "focus changed weights (seed \(seed), step \(step))") }
            if case .factsLearned = event { #expect(sameWeights(next, world), "facts changed weights (seed \(seed), step \(step))") }
            world = next
            let render = Renderer.render(world, area: area)
            let violations = Invariants.check(world, render: render, area: area)
            #expect(violations.isEmpty, "seed \(seed) step \(step) after \(event): \(violations)")
            if !violations.isEmpty { return }
        }
    }

    /// Workspaces present in both worlds carry the same weights (a pruned empty one is not a change).
    func sameWeights(_ a: World, _ b: World) -> Bool {
        let left = weights(of: a), right = weights(of: b)
        return Set(left.keys).intersection(right.keys).allSatisfy { left[$0] == right[$0] }
    }

    func weights(of world: World) -> [String: [[Int]]] {
        var result: [String: [[Int]]] = [:]
        for space in world.spaces.values {
            for workspace in space.workspaces { result["\(space.id)/\(workspace.name)"] = collect(workspace.root) }
        }
        return result
    }

    func collect(_ container: Container) -> [[Int]] {
        [container.weights] + container.children.flatMap { child -> [[Int]] in
            if case .container(let nested) = child { return collect(nested) }
            return []
        }
    }
}
