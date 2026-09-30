/// What the screen should look like for the active Space: where every visible window goes,
/// which windows must be hidden, and the order to raise them in.
public struct Render: Sendable, Equatable {
    /// Target frames for tiled windows that must be visible.
    public var frames: [WindowID: Rect] = [:]
    /// Windows of this Space that belong to a workspace not on screen (or to monocle's back).
    public var hidden: Set<WindowID> = []
    /// Windows to raise, front first: floating ones, the zoomed window, auto-floated ones, then
    /// the stack.
    public var front: [WindowID] = []
    /// Tiled windows taken out of the tiling by the `floatLargest` overflow policy (plan I10:
    /// a derived flag, the tree keeps them).
    public var autoFloated: [WindowID] = []
    public var plan = Solver.Plan()

    public init() {}
}

public enum Renderer {
    public static func tilingArea(_ area: Rect, settings: WorldSettings) -> Rect {
        let gap = settings.outerGap
        return area.inset(by: Insets(top: gap, left: gap, bottom: gap, right: gap))
    }

    /// The layout of one workspace, ignoring zoom and floating windows.
    public static func plan(for workspace: Workspace, area: Rect, facts: [WindowID: WindowFacts], settings: WorldSettings) -> Solver.Plan {
        let tiling = tilingArea(area, settings: settings)
        switch workspace.layout {
        case .monocle:
            return Solver.solveMonocle(windows: workspace.root.windows, in: tiling, facts: facts, focusOrder: workspace.mru)
        case .tiles, .accordion:
            let options = Solver.Options(innerGap: settings.innerGap, accordionPadding: settings.accordionPadding, overflow: settings.overflow)
            return Solver.solve(workspace.root, in: tiling, facts: facts, focusOrder: workspace.mru, options: options)
        }
    }

    public static func render(_ world: World, area: Rect) -> Render {
        var render = Render()
        guard let spaceID = world.activeSpace, let space = world.spaces[spaceID], space.kind == .desktop,
              let workspace = space.workspace(named: space.activeWorkspace) else { return render }

        var plan = plan(for: workspace, area: area, facts: world.facts, settings: world.settings)
        let tiling = tilingArea(area, settings: world.settings)
        if world.settings.overflow == .floatLargest, workspace.layout != .monocle {
            var reduced = workspace
            while plan.overflowed > 0 {
                let candidates = reduced.root.windows.filter { world.facts[$0]?.minSize != nil }
                guard reduced.root.windows.count > 1, let largest = candidates.max(by: { a, b in
                    let left = world.facts[a]!.minSize!, right = world.facts[b]!.minSize!
                    let areaA = left.width * left.height, areaB = right.width * right.height
                    return areaA != areaB ? areaA < areaB : a > b
                }) else { break }
                reduced.root.removeWindow(largest)
                if reduced.zoomed == largest { reduced.zoomed = nil }
                reduced.root = reduced.root.normalized()
                render.autoFloated.append(largest)
                plan = Self.plan(for: reduced, area: area, facts: world.facts, settings: world.settings)
            }
        }
        render.plan = plan

        if workspace.layout == .monocle {
            // Hybrid monocle: the two most recent windows stay stacked at full size so switching
            // between them is only a raise and closing one never flashes the desktop.
            let stack = plan.stacking
            for (index, id) in stack.enumerated() {
                if index < 2 { render.frames[id] = plan.frames[id] } else { render.hidden.insert(id) }
            }
            render.front = Array(stack.prefix(2))
        } else {
            render.frames = plan.frames
            render.front = plan.stacking.filter { _ in plan.overflowed > 0 || workspace.root.kind == .accordion }
        }

        if let zoomed = workspace.zoomed, workspace.root.contains(zoomed) {
            render.frames[zoomed] = tiling
            render.hidden.remove(zoomed)
            render.front.removeAll { $0 == zoomed }
            render.front.insert(zoomed, at: 0)
        }
        // Auto-floated windows keep the size they insist on, centred, in front of the tiling.
        render.autoFloated.removeAll { $0 == workspace.zoomed }
        for id in render.autoFloated {
            let minimum = world.facts[id]?.minSize ?? tiling.size
            let size = Size(width: min(minimum.width, tiling.width), height: min(minimum.height, tiling.height))
            render.frames[id] = Rect(
                x: tiling.minX + (tiling.width - size.width) / 2, y: tiling.minY + (tiling.height - size.height) / 2,
                width: size.width, height: size.height
            )
        }
        render.front.insert(contentsOf: render.autoFloated, at: workspace.zoomed == nil ? 0 : 1)
        // Floating windows (dialogs) stay in front of everything, the zoomed window included.
        render.front.insert(contentsOf: workspace.floating, at: 0)

        for other in space.workspaces where other.name != workspace.name {
            render.hidden.formUnion(other.windows)
        }
        return render
    }
}
