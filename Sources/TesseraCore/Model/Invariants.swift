/// The model-level invariants of `docs/invariants.md`, checked on a world and its render.
///
/// Tests assert that every reachable world passes; the engine runs the same check in debug
/// builds and on `tessera debug check`. Invariants that need the real screen (I7, I9, I11, I17,
/// I18) are checked by the engine against what it observed.
public enum Invariants {
    public struct Violation: Sendable, Hashable, CustomStringConvertible {
        public var invariant: String
        public var detail: String

        public init(_ invariant: String, _ detail: String) {
            self.invariant = invariant
            self.detail = detail
        }

        public var description: String { "\(invariant): \(detail)" }
    }

    public static func check(_ world: World, render: Render? = nil, area: Rect? = nil) -> [Violation] {
        var violations: [Violation] = []
        func fail(_ invariant: String, _ detail: String) { violations.append(Violation(invariant, detail)) }

        // I5: every window is in exactly one place, and only where its mode says.
        var seen: [WindowID: Int] = [:]
        for space in world.spaces.values {
            // I12: every Space has a workspace, and the active one exists.
            if space.workspaces.isEmpty { fail("I12", "space \(space.id) has no workspace") }
            if space.workspace(named: space.activeWorkspace) == nil { fail("I12", "space \(space.id) shows missing workspace \(space.activeWorkspace)") }
            if Set(space.workspaces.map(\.name)).count != space.workspaces.count { fail("I12", "space \(space.id) repeats a workspace name") }

            for workspace in space.workspaces {
                for id in workspace.root.windows + workspace.floating { seen[id, default: 0] += 1 }
                for id in workspace.root.windows {
                    guard let record = world.windows[id] else { fail("I5", "tree holds unknown window \(id)"); continue }
                    if record.mode != .tiled { fail("I5", "window \(id) is \(record.mode) but tiled in a tree") }
                    if record.space != space.id || record.workspace != workspace.name { fail("I5", "window \(id) sits in the wrong tree") }
                }
                for id in workspace.floating {
                    guard let record = world.windows[id] else { fail("I5", "floating list holds unknown window \(id)"); continue }
                    if record.mode != .floating { fail("I5", "window \(id) is \(record.mode) but in a floating list") }
                    if record.space != space.id || record.workspace != workspace.name { fail("I5", "window \(id) floats in the wrong workspace") }
                }
                // I8: MRU lists hold each window of their workspace at most once.
                if Set(workspace.mru).count != workspace.mru.count { fail("I8", "workspace \(workspace.name) repeats a window in its MRU") }
                for id in workspace.mru where world.windows[id].map({ $0.space != space.id || $0.workspace != workspace.name }) ?? true {
                    fail("I8", "MRU of \(workspace.name) holds foreign window \(id)")
                }
                // I10: a zoomed window is a tiled window of its own tree.
                if let zoomed = workspace.zoomed, !workspace.root.contains(zoomed) { fail("I10", "zoomed window \(zoomed) is not tiled here") }
                // I3 and I4: weights exact and above the floor; the tree is normalised.
                checkWeights(workspace.root, fail: fail)
                if workspace.root.normalized() != workspace.root { fail("I4", "tree of \(workspace.name) is not normalised") }
                // I15: hidden empty workspaces are pruned (minimised or hidden windows keep theirs).
                if workspace.isEmpty, workspace.name != space.activeWorkspace, workspace.name != space.previousWorkspace,
                   !world.windows.values.contains(where: { $0.space == space.id && $0.workspace == workspace.name }) {
                    fail("I15", "empty workspace \(workspace.name) kept")
                }
            }
        }
        for (id, count) in seen where count > 1 { fail("I5", "window \(id) appears \(count) times") }
        for record in world.windows.values {
            let placed = seen[record.id] ?? 0
            switch record.mode {
            case .tiled, .floating:
                if placed != 1 { fail("I5", "\(record.mode) window \(record.id) is in \(placed) places") }
            case .nativeFullscreen, .minimized, .appHidden:
                if placed != 0 { fail("I5", "\(record.mode) window \(record.id) is still placed") }
            }
            if world.spaces[record.space] == nil { fail("I5", "window \(record.id) points at missing space \(record.space)") }
        }
        // I8: the focused window exists.
        if let focused = world.focused, world.windows[focused] == nil { fail("I8", "focused window \(focused) does not exist") }
        for id in world.facts.keys where world.windows[id] == nil { fail("I8", "facts kept for gone window \(id)") }

        if let render, let area { checkRender(world, render, area, fail: fail) }
        return violations
    }

    static func checkWeights(_ container: Container, fail: (String, String) -> Void) {
        if container.weights.reduce(0, +) != Weights.total && !container.isEmpty { fail("I3", "weights sum to \(container.weights.reduce(0, +))") }
        let floor = Weights.floor(count: container.children.count)
        if container.weights.contains(where: { $0 < floor }) { fail("I3", "a weight is below the floor \(floor)") }
        for child in container.children {
            if case .container(let nested) = child {
                if nested.children.count < 2 { fail("I4", "nested container with \(nested.children.count) children") }
                checkWeights(nested, fail: fail)
            }
        }
    }

    static func checkRender(_ world: World, _ render: Render, _ area: Rect, fail: (String, String) -> Void) {
        guard let workspace = world.activeWorkspace, world.activeSpaceState?.kind == .desktop else {
            if !render.frames.isEmpty { fail("I16", "frames rendered for a Space Tessera does not tile") }
            return
        }
        let tiling = Renderer.tilingArea(area, settings: world.settings)
        let visible = Set(workspace.windows)
        // I16: the raise order names visible windows of this workspace, once each.
        if Set(render.front).count != render.front.count { fail("I16", "raise order repeats a window") }
        for id in render.front where !visible.contains(id) { fail("I16", "raises window \(id) from another workspace") }
        for id in render.frames.keys where !visible.contains(id) { fail("I16", "places window \(id) from another workspace") }
        if !render.hidden.isDisjoint(with: render.frames.keys) { fail("I16", "a window is both placed and hidden") }
        // Every tiled window of the workspace is either placed or hidden.
        for id in workspace.root.windows where render.frames[id] == nil && !render.hidden.contains(id) {
            fail("I16", "tiled window \(id) neither placed nor hidden")
        }
        // Windows of other workspaces of this Space are hidden.
        for other in world.activeSpaceState?.workspaces ?? [] where other.name != workspace.name {
            for id in other.windows where !render.hidden.contains(id) { fail("I16", "window \(id) of hidden workspace \(other.name) not hidden") }
        }

        let partition = workspace.layout != .monocle && workspace.zoomed == nil && render.plan.overflowed == 0
            && workspace.root.kind == .tiles && render.autoFloated.isEmpty && !containsAccordion(workspace.root)
        if partition, !workspace.root.isEmpty, world.settings.innerGap == 0 {
            // I1: the tiles partition the tiling area exactly.
            let tiles = workspace.root.windows.compactMap { render.plan.tiles[$0] }
            let covered = tiles.reduce(0) { $0 + $1.width * $1.height }
            if covered != tiling.width * tiling.height { fail("I1", "tiles cover \(covered) of \(tiling.width * tiling.height) points") }
            for (index, tile) in tiles.enumerated() {
                // I1b: every tile is non-empty and inside the area.
                if tile.width <= 0 || tile.height <= 0 { fail("I1b", "empty tile \(tile)") }
                if !tiling.contains(tile) { fail("I1", "tile \(tile) leaves the area") }
                for other in tiles[(index + 1)...] where tile.intersects(other) { fail("I1", "tiles \(tile) and \(other) overlap") }
            }
        }
        // I13: placed windows stay inside the area, unless their minimum does not fit in it or
        // the policy allows spilling.
        if world.settings.overflow != .allow {
            for (id, frame) in render.frames where !tiling.contains(frame) {
                let minimum = world.facts[id]?.minSize
                let oversized = minimum.map { $0.width > tiling.width || $0.height > tiling.height } ?? false
                if !oversized { fail("I13", "window \(id) at \(frame) leaves \(tiling)") }
            }
        }
        // I19: monocle shows one window in front with the whole area, at most one more below it.
        if workspace.layout == .monocle, workspace.zoomed == nil, !workspace.root.isEmpty {
            let shown = workspace.root.windows.filter { render.frames[$0] != nil }
            if shown.isEmpty || shown.count > 2 { fail("I19", "monocle shows \(shown.count) windows") }
            if let first = render.front.first(where: { workspace.root.contains($0) }), render.plan.tiles[first] != tiling {
                fail("I19", "front window of monocle does not own the whole area")
            }
        }
    }

    static func containsAccordion(_ container: Container) -> Bool {
        container.kind == .accordion || container.children.contains {
            if case .container(let nested) = $0 { return containsAccordion(nested) }
            return false
        }
    }
}
