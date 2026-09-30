import Testing
@testable import TesseraCore

/// End-to-end behaviour of the pure model on the owner's single portrait monitor.
struct ScenarioTests {
    let area = Rect(x: 0, y: 30, width: 1080, height: 2448)
    let desktop: SpaceID = 3
    let secondDesktop: SpaceID = 7
    let fullscreenSpace: SpaceID = 183

    func world(spaces: [SpaceDescriptor], active: SpaceID) -> World {
        Reducer.reduce(World(), .spacesChanged(spaces, active: active), area: area)
    }

    func apply(_ world: World, _ events: [Event]) -> World {
        events.reduce(world) { Reducer.reduce($0, $1, area: area) }
    }

    func open(_ id: WindowID, space: SpaceID, pid: Int32 = 100) -> [Event] {
        [.windowObserved(WindowObservation(id: id, pid: pid, space: space)), .focusChanged(id)]
    }

    @Test func singleDesktopStacksWindowsVerticallyWithoutHoles() {
        var w = world(spaces: [SpaceDescriptor(id: desktop, kind: .desktop)], active: desktop)
        w = apply(w, open(1, space: desktop) + open(2, space: desktop) + open(3, space: desktop))
        let render = Renderer.render(w, area: area)
        #expect(render.frames[1] == Rect(x: 0, y: 30, width: 1080, height: 816))
        #expect(render.frames[2] == Rect(x: 0, y: 846, width: 1080, height: 816))
        #expect(render.frames[3] == Rect(x: 0, y: 1662, width: 1080, height: 816))
        #expect(render.hidden.isEmpty)
    }

    @Test func closingAWindowGivesItsSpaceBack() {
        var w = world(spaces: [SpaceDescriptor(id: desktop, kind: .desktop)], active: desktop)
        w = apply(w, open(1, space: desktop) + open(2, space: desktop) + open(3, space: desktop) + [.windowGone(2)])
        let render = Renderer.render(w, area: area)
        #expect(render.frames[1] == Rect(x: 0, y: 30, width: 1080, height: 1224))
        #expect(render.frames[3] == Rect(x: 0, y: 1254, width: 1080, height: 1224))
        #expect(w.focused == 3, "closing an unfocused window keeps the focus")
        w = apply(w, [.windowGone(3)])
        #expect(w.focused == 1, "closing the focused window hands focus to the previous one")
    }

    @Test func everyNativeSpaceTilesIndependently() {
        var w = world(spaces: [SpaceDescriptor(id: desktop, kind: .desktop), SpaceDescriptor(id: secondDesktop, kind: .desktop)], active: desktop)
        w = apply(w, open(1, space: desktop) + open(2, space: desktop))
        w = apply(w, [.spacesChanged([SpaceDescriptor(id: desktop, kind: .desktop), SpaceDescriptor(id: secondDesktop, kind: .desktop)], active: secondDesktop)])
        w = apply(w, open(10, space: secondDesktop))

        let second = Renderer.render(w, area: area)
        #expect(second.frames == [10: area])
        #expect(second.hidden.isEmpty, "windows of another native Space are macOS's business, never hidden by Tessera")

        w = apply(w, [.spacesChanged([SpaceDescriptor(id: desktop, kind: .desktop), SpaceDescriptor(id: secondDesktop, kind: .desktop)], active: desktop)])
        let first = Renderer.render(w, area: area)
        #expect(first.frames.keys.sorted() == [1, 2])
    }

    @Test func nativeFullscreenWindowsAreNeverTiled() {
        var w = world(spaces: [SpaceDescriptor(id: desktop, kind: .desktop), SpaceDescriptor(id: fullscreenSpace, kind: .fullscreen)], active: desktop)
        w = apply(w, open(1, space: desktop) + open(2, space: desktop))
        // The user presses the green button on window 2: macOS moves it to its own Space.
        w = apply(w, [.windowObserved(WindowObservation(id: 2, pid: 100, space: fullscreenSpace, isNativeFullscreen: true))])
        #expect(w.windows[2]?.mode == .nativeFullscreen)
        #expect(Renderer.render(w, area: area).frames == [1: area])

        // Inside the full-screen Space Tessera does nothing at all.
        w = apply(w, [.spacesChanged([SpaceDescriptor(id: desktop, kind: .desktop), SpaceDescriptor(id: fullscreenSpace, kind: .fullscreen)], active: fullscreenSpace)])
        #expect(Renderer.render(w, area: area) == Render())

        // Leaving full screen puts it back in the tiling.
        w = apply(w, [
            .spacesChanged([SpaceDescriptor(id: desktop, kind: .desktop)], active: desktop),
            .windowObserved(WindowObservation(id: 2, pid: 100, space: desktop)),
        ])
        #expect(Renderer.render(w, area: area).frames.keys.sorted() == [1, 2])
    }

    @Test func tesseraFullscreenCoversTheDesktopAndRestoresTheTiling() {
        var w = world(spaces: [SpaceDescriptor(id: desktop, kind: .desktop)], active: desktop)
        w = apply(w, open(1, space: desktop) + open(2, space: desktop) + [.command(.toggleFullscreen)])
        var render = Renderer.render(w, area: area)
        #expect(render.frames[2] == area)
        #expect(render.front.first == 2)
        #expect(render.frames[1] == Rect(x: 0, y: 30, width: 1080, height: 1224), "the tiling stays behind")

        w = apply(w, [.command(.toggleFullscreen)])
        render = Renderer.render(w, area: area)
        #expect(render.frames[2] == Rect(x: 0, y: 1254, width: 1080, height: 1224))
    }

    @Test func fullscreenIsAlwaysAToggleAndFollowsFocus() {
        var w = world(spaces: [SpaceDescriptor(id: desktop, kind: .desktop)], active: desktop)
        w = apply(w, open(1, space: desktop) + open(2, space: desktop) + [.command(.toggleFullscreen)])
        #expect(w.activeWorkspace?.zoomed == 2)
        // Moving the focus while in full screen hands full screen to the next window.
        w = apply(w, [.command(.focus(.up))])
        #expect(w.focused == 1 && w.activeWorkspace?.zoomed == 1)
        #expect(Renderer.render(w, area: area).frames[1] == area)
        // The shortcut leaves full screen even if focus changed meanwhile.
        w = apply(w, [.focusChanged(2), .command(.toggleFullscreen)])
        #expect(w.activeWorkspace?.zoomed == nil)
    }

    @Test func draggingOneWindowOntoAnotherSwapsThem() {
        var w = world(spaces: [SpaceDescriptor(id: desktop, kind: .desktop)], active: desktop)
        w = apply(w, open(1, space: desktop) + open(2, space: desktop) + open(3, space: desktop))
        let before = Renderer.render(w, area: area)
        w = apply(w, [.command(.swapWindows(1, 3))])
        let after = Renderer.render(w, area: area)
        #expect(after.frames[1] == before.frames[3])
        #expect(after.frames[3] == before.frames[1])
        #expect(after.frames[2] == before.frames[2])
    }

    @Test func mouseResizeMovesOnlyTheDraggedEdge() {
        var w = world(spaces: [SpaceDescriptor(id: desktop, kind: .desktop)], active: desktop)
        w = apply(w, open(1, space: desktop) + open(2, space: desktop) + open(3, space: desktop))
        // The user drags the bottom edge of window 1 down by 200 points.
        let tile = Renderer.render(w, area: area).frames[1]!
        w = apply(w, [.command(.resizeWindow(1, to: Rect(x: tile.x, y: tile.y, width: tile.width, height: tile.height + 200)))])
        let render = Renderer.render(w, area: area)
        #expect(render.frames[1]!.height == 1016)
        #expect(render.frames[2]!.height == 616)
        #expect(render.frames[3]!.height == 816)
        // Dragging the top edge of window 3 up by 100 takes the space from window 2.
        let third = render.frames[3]!
        w = apply(w, [.command(.resizeWindow(3, to: Rect(x: third.x, y: third.y - 100, width: third.width, height: third.height + 100)))])
        let final = Renderer.render(w, area: area)
        #expect(final.frames[1]!.height == 1016)
        #expect(final.frames[2]!.height == 516)
        #expect(final.frames[3]!.height == 916)
    }

    @Test func tesseraWorkspacesNestInsideANativeSpace() {
        var w = world(spaces: [SpaceDescriptor(id: desktop, kind: .desktop)], active: desktop)
        w = apply(w, open(1, space: desktop) + open(2, space: desktop))
        w = apply(w, [.command(.workspace("2"))])
        w = apply(w, open(3, space: desktop))

        var render = Renderer.render(w, area: area)
        #expect(render.frames == [3: area])
        #expect(render.hidden == [1, 2])

        w = apply(w, [.command(.workspaceBackAndForth)])
        render = Renderer.render(w, area: area)
        #expect(render.frames.keys.sorted() == [1, 2])
        #expect(render.hidden == [3])
    }

    @Test func focusLandingOnAHiddenWorkspaceBringsItForward() {
        var w = world(spaces: [SpaceDescriptor(id: desktop, kind: .desktop)], active: desktop)
        w = apply(w, open(1, space: desktop) + [.command(.workspace("2"))] + open(2, space: desktop))
        w = apply(w, [.focusChanged(1)]) // Cmd-Tab to the app of window 1
        #expect(w.activeSpaceState?.activeWorkspace == "1")
        #expect(Renderer.render(w, area: area).hidden == [2])
    }

    @Test func movingToTheEdgeSplitsThePortraitColumn() {
        var w = world(spaces: [SpaceDescriptor(id: desktop, kind: .desktop)], active: desktop)
        w = apply(w, open(1, space: desktop) + open(2, space: desktop) + open(3, space: desktop))
        w = apply(w, [.command(.move(.right))])
        let render = Renderer.render(w, area: area)
        // Window 3 now owns the right half; 1 and 2 share the left column.
        #expect(render.frames[3] == Rect(x: 540, y: 30, width: 540, height: 2448))
        #expect(render.frames[1] == Rect(x: 0, y: 30, width: 540, height: 1224))
        #expect(render.frames[2] == Rect(x: 0, y: 1254, width: 540, height: 1224))
    }

    @Test func focusAndSwapFollowTheScreen() {
        var w = world(spaces: [SpaceDescriptor(id: desktop, kind: .desktop)], active: desktop)
        w = apply(w, open(1, space: desktop) + open(2, space: desktop))
        w = apply(w, [.command(.focus(.up))])
        #expect(w.focused == 1)
        w = apply(w, [.command(.move(.down))])
        let render = Renderer.render(w, area: area)
        #expect(render.frames[1] == Rect(x: 0, y: 1254, width: 1080, height: 1224))
        #expect(w.focused == 1)
    }

    @Test func resizeShiftsOnlyTheNeighbour() {
        var w = world(spaces: [SpaceDescriptor(id: desktop, kind: .desktop)], active: desktop)
        w = apply(w, open(1, space: desktop) + open(2, space: desktop) + open(3, space: desktop) + [.focusChanged(1)])
        w = apply(w, [.command(.resize(.height, points: 200))])
        let render = Renderer.render(w, area: area)
        #expect(render.frames[1]!.height == 1016)
        #expect(render.frames[2]!.height == 616)
        #expect(render.frames[3]!.height == 816)
    }

    @Test func monocleKeepsTwoStackedAndHidesTheRest() {
        var w = world(spaces: [SpaceDescriptor(id: desktop, kind: .desktop)], active: desktop)
        w = apply(w, open(1, space: desktop) + open(2, space: desktop) + open(3, space: desktop) + [.command(.layout(.monocle))])
        let render = Renderer.render(w, area: area)
        #expect(render.front == [3, 2])
        #expect(render.frames[3] == area && render.frames[2] == area)
        #expect(render.hidden == [1])
    }

    @Test func floatingWindowsLeaveTheTiling() {
        var w = world(spaces: [SpaceDescriptor(id: desktop, kind: .desktop)], active: desktop)
        w = apply(w, open(1, space: desktop) + [.windowObserved(WindowObservation(id: 2, pid: 5, space: desktop, prefersFloating: true))])
        let render = Renderer.render(w, area: area)
        #expect(render.frames == [1: area])
        #expect(render.front == [2])
    }
}
