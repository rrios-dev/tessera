import Foundation
import TesseraCore
import TesseraPorts

extension Engine {
    /// While a window is dragged, what the drop would do is highlighted (audit E8): the tile a
    /// tiled window would swap with, or the half of a tile a floating window would be inserted
    /// into (nothing while ⌥ is held: the window stays floating).
    func mouseDragged(to point: Point) {
        guard status.isActive, mouseIsDown, !draggedByUser.isEmpty, let area = tilingArea else {
            clearDropTarget()
            return
        }
        // A resize is not a move: only a window that keeps its size is being carried somewhere,
        // so only then is a drop target shown (owner, 2026-09-27: resizing lit up the neighbour).
        guard draggedByUser.allSatisfy({ !isBeingResized($0) }) else {
            clearDropTarget()
            return
        }
        let render = Renderer.render(world, area: area)
        var target: Rect?
        if let (anchor, tile) = render.plan.tiles.first(where: { !draggedByUser.contains($0.key) && $0.value.contains(point) }) {
            let floating = draggedByUser.contains { world.windows[$0]?.mode == .floating }
            if !floating {
                target = tile
            } else if !modifiersHeld.contains(.option) {
                target = insertionSlot(beside: anchor, tile: tile, at: point).rect
            }
        }
        guard target != dropTarget else { return }
        dropTarget = target
        ui.showDropTarget(target)
    }

    /// Where a floating window dropped at `point` over `tile` goes: before or after the anchor,
    /// along the axis its container runs.
    func insertionSlot(beside anchor: WindowID, tile: Rect, at point: Point) -> (after: Bool, rect: Rect) {
        let primary = tilingArea.map { Solver.primaryAxis(for: Renderer.tilingArea($0, settings: world.settings)) } ?? .vertical
        var axis: Axis = primary
        if let workspace = world.workspace(of: anchor), let path = workspace.root.path(to: anchor),
           let parent = workspace.root.container(at: Array(path.dropLast())) {
            axis = parent.axis.resolve(primary: primary)
        }
        if axis == .vertical {
            let after = point.y >= tile.y + tile.height / 2
            return (after, Rect(x: tile.x, y: after ? tile.y + tile.height / 2 : tile.y, width: tile.width, height: tile.height / 2))
        }
        let after = point.x >= tile.x + tile.width / 2
        return (after, Rect(x: after ? tile.x + tile.width / 2 : tile.x, y: tile.y, width: tile.width / 2, height: tile.height))
    }

    /// Whether a dragged window's size has changed since the drag began.
    func isBeingResized(_ id: WindowID) -> Bool {
        guard let start = dragStart[id], let now = observed[id] else { return false }
        return abs(start.width - now.width) > 2 || abs(start.height - now.height) > 2
    }

    func clearDropTarget() {
        guard dropTarget != nil else { return }
        dropTarget = nil
        ui.showDropTarget(nil)
    }

    /// The mouse button went up: a tiled window dropped on another swaps with it, a resized one
    /// shares its new size with its neighbour, anything else goes back to its tile.
    func finishDrag(at point: Point) {
        clearDropTarget()
        let dragged = draggedByUser
        log.debug("mouse up at \(point); dragged \(dragged)")
        // The same release can arrive twice; the first one takes the drag.
        guard !dragged.isEmpty, !resolvingDrop else {
            scheduleRender()
            return
        }
        draggedByUser.removeAll()
        resolvingDrop = true
        // Let the window settle where the hand left it, then read what the window server draws.
        after(timing.dropSettle) { [weak self] in self?.completeDrag(dragged, at: point) }
    }

    /// Reads every dropped window's frame again before deciding: during a live resize the
    /// Accessibility notifications arrive coalesced, and the last one can predate the release
    /// (owner, 2026-09-27: a resize snapped back because Tessera judged a stale frame). The window
    /// server's bounds are not used for the size: they include a 1-point outline on macOS 26.
    func completeDrag(_ dragged: Set<WindowID>, at point: Point) {
        let countdown = Countdown(dragged.count) { [weak self] in
            guard let self else { return }
            self.resolvingDrop = false
            self.scheduleRender()
        }
        for id in dragged {
            guard let driver = driver(for: id) else {
                countdown.tick()
                continue
            }
            driver.frame(of: id) { [weak self] frame in
                self?.onMain { [weak self] in
                    defer { countdown.tick() }
                    guard let self, self.world.windows[id] != nil else { return }
                    if let frame { self.observed[id] = frame }
                    self.resolveDrop(of: id, at: point)
                }
            }
        }
        after(max(timing.shutdownWait, 1)) { countdown.finish() }
    }

    func resolveDrop(of id: WindowID, at point: Point) {
        guard let area = tilingArea else { return }
        let render = Renderer.render(world, area: area)
        // The hand is back in charge of this window: any backoff ends.
        backoff[id] = nil
        writeLog[id] = nil
        if world.windows[id]?.mode == .floating {
            dropFloating(id, at: point, render: render, drawn: observed[id])
            return
        }
        guard let target = render.frames[id], let drawn = observed[id] else { return }
        let widthChanged = abs(drawn.width - target.width) > 2
        let heightChanged = abs(drawn.height - target.height) > 2
        if widthChanged || heightChanged {
            resizedByHand(id, to: drawn, widthChanged: widthChanged, heightChanged: heightChanged, area: area)
        } else if drawn.origin != target.origin,
                  let other = render.plan.tiles.first(where: { $0.key != id && $0.value.contains(point) })?.key {
            dispatch(.command(.swapWindows(id, other)))
            pendingFocus = (id, port.now())
        }
        requested[id] = nil
    }

    /// A floating window the user floated (or that did not fit) dropped by its title bar onto a
    /// tile joins the tiling there, above or below (left or right of) that window. Held ⌥, a
    /// resize, or a drop outside the tiling leaves it floating where it is.
    func dropFloating(_ id: WindowID, at point: Point, render: Render, drawn: Rect?) {
        guard world.windows[id]?.userFloating == true, !modifiersHeld.contains(.option),
              let start = dragStart[id], let drawn, abs(start.width - drawn.width) <= 2, abs(start.height - drawn.height) <= 2,
              let (anchor, tile) = render.plan.tiles.first(where: { $0.key != id && $0.value.contains(point) }) else { return }
        let slot = insertionSlot(beside: anchor, tile: tile, at: point)
        dispatch(.command(.insertWindow(id, beside: anchor, after: slot.after)))
        requested[id] = nil
        pendingFocus = (id, port.now())
    }

    /// A resize by hand is applied as far as the tiling can express it — the height in a column,
    /// the width in a row — and never takes the window out of the tiling: the rest goes back to
    /// the tile (owner, 2026-09-26: floating a window on a width change left the browsers one
    /// behind the other, apparently unmanaged). Floating stays an explicit choice (⌃⌥⇧Space).
    func resizedByHand(_ id: WindowID, to drawn: Rect, widthChanged: Bool, heightChanged: Bool, area: Rect) {
        dispatch(.command(.resizeWindow(id, to: drawn)))
        let after = Renderer.render(world, area: area).frames[id]
        let honoured = after.map { frame in
            (!widthChanged || abs(frame.width - drawn.width) <= 12) && (!heightChanged || abs(frame.height - drawn.height) <= 12)
        } ?? false
        guard !honoured else { return }
        let times = noticeCounts["resize-limited", default: 0]
        notify(Notice("resize-limited", .info, L10n.t(
            "El mosaico solo puede repartir parte de ese cambio; el resto vuelve a su sitio. Para colocar la ventana libre, ⌃⌥⇧Espacio.",
            "The tiling can only share part of that change; the rest goes back. To place the window freely, ⌃⌥⇧Space."
        ), onScreen: times < 3))
    }
}
