import Testing
@testable import TesseraCore

/// Regressions for the findings of docs/audit/2026-09-25-maturity-audit.md that live in the core.
struct AuditRegressionTests {
    let area = Rect(x: 0, y: 30, width: 1080, height: 2448)
    let desktop: SpaceID = 3

    func world(_ settings: WorldSettings = WorldSettings(), windows: [WindowID]) -> World {
        var w = Reducer.reduce(World(settings: settings), .spacesChanged([SpaceDescriptor(id: desktop, kind: .desktop)], active: desktop), area: area)
        for id in windows {
            w = Reducer.reduce(w, .windowObserved(WindowObservation(id: id, pid: 100, space: desktop)), area: area)
            w = Reducer.reduce(w, .focusChanged(id), area: area)
        }
        return w
    }

    func run(_ w: World, _ commands: Command...) -> World {
        commands.reduce(w) { Reducer.reduce($0, .command($1), area: area) }
    }

    // D1: directional focus walks the tree where tiles overlap.
    @Test func focusMovesInMonocle() {
        var w = run(world(windows: [1, 2, 3]), .layout(.monocle), .focusWindow(2))
        w = run(w, .focus(.down))
        #expect(w.focused == 3)
        w = run(w, .focus(.up), .focus(.up))
        #expect(w.focused == 1)
        w = run(w, .focus(.up))
        #expect(w.focused == 1, "no wrap-around at the ends")
    }

    @Test func focusMovesInAccordion() {
        var w = run(world(windows: [1, 2, 3]), .layout(.accordion), .focusWindow(1))
        // A portrait area: the accordion runs vertically, so down is the next window.
        w = run(w, .focus(.down))
        #expect(w.focused == 2)
        w = run(w, .focus(.up))
        #expect(w.focused == 1)
    }

    @Test func focusMovesAmongOverflowedWindows() {
        var w = world(WorldSettings(overflow: .accordion), windows: [1, 2])
        // Neither fits beside or above the other: the container overflows into an accordion.
        w = Reducer.reduce(w, .factsLearned(1, WindowFacts(minSize: Size(width: 900, height: 2000))), area: area)
        w = Reducer.reduce(w, .factsLearned(2, WindowFacts(minSize: Size(width: 900, height: 2000))), area: area)
        #expect(Renderer.render(w, area: area).plan.overflowed == 1)
        w = run(w, .focusWindow(1), .focus(.down))
        #expect(w.focused == 2)
    }

    // D2: the user's float/tile choice survives rescans, minimising and hiding.
    @Test func userFloatChoiceIsKept() {
        var w = run(world(windows: [1, 2]), .focusWindow(2), .toggleFloating)
        #expect(w.windows[2]?.mode == .floating)
        w = Reducer.reduce(w, .windowObserved(WindowObservation(id: 2, pid: 100, space: desktop, isMinimized: true)), area: area)
        w = Reducer.reduce(w, .windowObserved(WindowObservation(id: 2, pid: 100, space: desktop)), area: area)
        #expect(w.windows[2]?.mode == .floating, "a floated window comes back floating")

        // A dialog the user tiled stays tiled when the next scan says it prefers floating.
        w = Reducer.reduce(w, .windowObserved(WindowObservation(id: 9, pid: 100, space: desktop, prefersFloating: true)), area: area)
        w = run(w, .focusWindow(9), .toggleFloating)
        #expect(w.windows[9]?.mode == .tiled)
        w = Reducer.reduce(w, .windowObserved(WindowObservation(id: 9, pid: 100, space: desktop, isAppHidden: true)), area: area)
        w = Reducer.reduce(w, .windowObserved(WindowObservation(id: 9, pid: 100, space: desktop, prefersFloating: true)), area: area)
        #expect(w.windows[9]?.mode == .tiled)
    }

    // D3: a dialog stays in front of a window in Tessera full screen.
    @Test func floatingWindowsStayInFrontOfTheZoomedWindow() {
        var w = run(world(windows: [1, 2]), .focusWindow(1), .toggleFullscreen)
        w = Reducer.reduce(w, .windowObserved(WindowObservation(id: 5, pid: 100, space: desktop, prefersFloating: true)), area: area)
        let render = Renderer.render(w, area: area)
        #expect(render.front.first == 5)
        #expect(render.front.firstIndex(of: 1)! > render.front.firstIndex(of: 5)!)
    }

    // D5: a window on every desktop floats instead of being re-tiled on each switch.
    @Test func setFloatingIsTheUsersChoice() {
        var w = run(world(windows: [1, 2]), .setFloating(1, true))
        #expect(w.windows[1]?.mode == .floating && w.windows[1]?.userFloating == true)
        w = Reducer.reduce(w, .windowObserved(WindowObservation(id: 1, pid: 100, space: desktop)), area: area)
        #expect(w.windows[1]?.mode == .floating, "a rescan keeps it floating")
        w = run(w, .setFloating(1, false))
        #expect(w.windows[1]?.mode == .tiled)
        #expect(Invariants.check(w, render: Renderer.render(w, area: area), area: area).isEmpty)
    }

    @Test func aFloatingWindowIsInsertedBesideAnother() {
        var w = run(world(windows: [1, 2, 3]), .setFloating(3, true))
        w = run(w, .insertWindow(3, beside: 1, after: true))
        #expect(w.activeWorkspace?.root.windows == [1, 3, 2])
        #expect(w.windows[3]?.mode == .tiled && w.windows[3]?.userFloating == false)
        #expect(w.focused == 3)
        w = run(w, .setFloating(2, true), .insertWindow(2, beside: 1, after: false))
        #expect(w.activeWorkspace?.root.windows == [2, 1, 3])
        #expect(Invariants.check(w, render: Renderer.render(w, area: area), area: area).isEmpty)
    }

    @Test func theDefaultOverflowFloatsInsteadOfStacking() {
        #expect(WorldSettings().overflow == .floatLargest)
    }

    @Test func windowsOnAllSpacesFloat() {
        let w = Reducer.reduce(world(windows: [1]), .windowObserved(WindowObservation(id: 4, pid: 100, space: desktop, isOnAllSpaces: true)), area: area)
        #expect(w.windows[4]?.mode == .floating)
    }

    // B2: huge resizes neither trap nor corrupt the weights.
    @Test func extremeResizesAreClamped() {
        var w = world(windows: [1, 2])
        w = run(w, .resize(.height, points: Int.max), .resize(.height, points: Int.min), .resize(.width, points: Int.max))
        w = run(w, .resizeWindow(1, to: Rect(x: 0, y: 30, width: Int.max / 4, height: Int.max / 4)))
        #expect(Invariants.check(w, render: Renderer.render(w, area: area), area: area).isEmpty)
    }

    @Test func workspaceNamesFollowTheGrammar() {
        #expect(Command.isValidWorkspaceName("1"))
        #expect(Command.isValidWorkspaceName("web-2_x"))
        #expect(!Command.isValidWorkspaceName(""))
        #expect(!Command.isValidWorkspaceName("a b"))
        #expect(!Command.isValidWorkspaceName(String(repeating: "a", count: 17)))
        #expect(!Command.isValidWorkspaceName("ñ"))
    }

    // D4: overflow policies.
    func overflowing(_ policy: OverflowPolicy, count: Int) -> World {
        var w = world(WorldSettings(overflow: policy), windows: Array(1...WindowID(count)))
        for id in 1...WindowID(count) {
            w = Reducer.reduce(w, .factsLearned(id, WindowFacts(minSize: Size(width: 900, height: 1500 + Int(id)))), area: area)
        }
        return w
    }

    @Test func accordionOverflowStacksBeyondFourWindows() {
        let few = Renderer.render(overflowing(.accordion, count: 3), area: area)
        #expect(few.plan.overflowed == 1 && few.plan.stacked == 0)
        let many = Renderer.render(overflowing(.accordion, count: 5), area: area)
        #expect(many.plan.stacked == 1)
        #expect(Set(many.plan.tiles.values) == [area], "stacked windows each get the whole area")
    }

    @Test func floatLargestTakesWindowsOutUntilTheRestFits() {
        let w = overflowing(.floatLargest, count: 2)
        let render = Renderer.render(w, area: area)
        #expect(render.autoFloated == [2], "the window with the largest minimum floats")
        #expect(render.plan.overflowed == 0)
        #expect(render.frames[2]!.width == 900 && area.contains(render.frames[2]!))
        #expect(Invariants.check(w, render: render, area: area).isEmpty)
    }

    @Test func framesLargerThanTheirTileStayInsideTheArea() {
        let render = Renderer.render(overflowing(.accordion, count: 2), area: area)
        for frame in render.frames.values { #expect(area.contains(frame), "\(frame)") }
    }

    @Test func allowPolicyLetsWindowsSpill() {
        let render = Renderer.render(overflowing(.allow, count: 2), area: area)
        #expect(render.frames.values.contains { !area.contains($0) })
    }

    @Test func gapsAreBounded() {
        let settings = WorldSettings(innerGap: 1_000_000, outerGap: -5)
        #expect(settings.innerGap == WorldSettings.maxGap)
        #expect(settings.outerGap == 0)
    }
}

extension AuditRegressionTests {
    @Test func movingTheFocusedWindowAwayFocusesAnotherWindowOfTheSource() {
        var w = world(windows: [1, 2])
        w = Reducer.reduce(w, .focusChanged(nil), area: area)
        w.spaces[desktop]!.modifyWorkspace(named: "1") { $0.mru = [] }
        w = run(w, .focusWindow(1), .moveNodeToWorkspace("2"))
        #expect(w.focused == 2)
        #expect(w.activeWorkspace?.name == "1")
    }
}
