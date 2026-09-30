import TesseraCore

/// Seeded random event sequences through the reducer, every invariant checked after every
/// event. The unit suite runs a slice; this is the long run (plan §12: 10⁶ steps).
enum ModelRun {
    static let spaces = [SpaceDescriptor(id: 3, kind: .desktop), SpaceDescriptor(id: 7, kind: .desktop), SpaceDescriptor(id: 90, kind: .fullscreen)]
    static let areas = [Rect(x: 0, y: 30, width: 1080, height: 2447), Rect(x: 0, y: 25, width: 2560, height: 1415), Rect(x: 0, y: 25, width: 1512, height: 957)]

    static func run(steps: Int) -> Int32 {
        let perSequence = 500
        var violations = 0
        var sequences = 0
        var step = 0
        while step < steps {
            var rng = Generator(state: UInt64(sequences) &* 0x9E37_79B9 &+ 17)
            let area = areas[sequences % areas.count]
            var world = World(settings: WorldSettings(overflow: OverflowPolicy.allCases[sequences % 4]))
            world = Reducer.reduce(world, .spacesChanged(spaces, active: 3), area: area)
            var nextWindow: WindowID = 1
            for local in 0..<perSequence where step < steps {
                let event = randomEvent(world, &rng, &nextWindow)
                world = Reducer.reduce(world, event, area: area)
                let found = Invariants.check(world, render: Renderer.render(world, area: area), area: area)
                if !found.isEmpty {
                    violations += 1
                    if violations <= 10 { print("sequence \(sequences) step \(local) after \(event): \(found)") }
                    break
                }
                step += 1
            }
            sequences += 1
        }
        print("model run: \(step) steps in \(sequences) sequences, \(violations) violation(s)")
        return violations == 0 ? 0 : 1
    }

    static func pick<T>(_ values: [T], _ rng: inout Generator) -> T { values[Int.random(in: 0..<values.count, using: &rng)] }

    static func randomEvent(_ world: World, _ rng: inout Generator, _ nextWindow: inout WindowID) -> Event {
        let known = Array(world.windows.keys).sorted()
        switch Int.random(in: 0..<100, using: &rng) {
        case 0..<18:
            nextWindow += 1
            return .windowObserved(WindowObservation(
                id: nextWindow, pid: Int32.random(in: 100...104, using: &rng), space: pick([3, 3, 7, 90, nil], &rng),
                isNativeFullscreen: Int.random(in: 0..<20, using: &rng) == 0,
                prefersFloating: Int.random(in: 0..<6, using: &rng) == 0, isOnAllSpaces: Int.random(in: 0..<25, using: &rng) == 0
            ))
        case 18..<28 where !known.isEmpty:
            let id = pick(known, &rng)
            return .windowObserved(WindowObservation(
                id: id, pid: world.windows[id]!.pid, space: pick([world.windows[id]!.space, 3, 7], &rng),
                isMinimized: Int.random(in: 0..<3, using: &rng) == 0, isAppHidden: Int.random(in: 0..<5, using: &rng) == 0,
                prefersFloating: Int.random(in: 0..<6, using: &rng) == 0
            ))
        case 28..<38 where !known.isEmpty: return .windowGone(pick(known, &rng))
        case 38..<48: return .focusChanged(known.isEmpty ? nil : pick(known, &rng))
        case 48..<53: return .spacesChanged(spaces, active: pick([3, 7, 90], &rng))
        case 53..<58 where !known.isEmpty:
            return .factsLearned(pick(known, &rng), WindowFacts(minSize: Size(width: Int.random(in: 200...1800, using: &rng), height: Int.random(in: 100...900, using: &rng))))
        default:
            let commands: [Command] = [
                .focus(pick(Direction.allCases, &rng)), .move(pick(Direction.allCases, &rng)), .workspace(pick(["1", "2", "3", "web"], &rng)),
                .workspaceBackAndForth, .moveNodeToWorkspace(pick(["1", "2", "3"], &rng)), .layout(pick(LayoutMode.allCases, &rng)),
                .toggleOrientation, .toggleFloating, .toggleFullscreen, .balanceSizes,
                .resize(pick([.width, .height], &rng), points: pick([-50, 50, 400, -Int.max, Int.max], &rng)),
            ]
            if !known.isEmpty, Int.random(in: 0..<4, using: &rng) == 0 {
                return .command(pick([.swapWindows(pick(known, &rng), pick(known, &rng)), .focusWindow(pick(known, &rng)),
                                      .insertWindow(pick(known, &rng), beside: pick(known, &rng), after: Bool.random(using: &rng)), .setFloating(pick(known, &rng), Bool.random(using: &rng)),
                                      .resizeWindow(pick(known, &rng), to: Rect(x: 0, y: 30, width: Int.random(in: 1...3000, using: &rng), height: Int.random(in: 1...3000, using: &rng)))], &rng))
            }
            return .command(pick(commands, &rng))
        }
    }
}
