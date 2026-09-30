/// Neighbours between windows, the way a person reads the screen.
public enum Navigation {
    /// The closest tile in `direction` that overlaps the source on the perpendicular axis;
    /// ties go to the larger overlap, then to the lower window id.
    public static func neighbor(of source: WindowID, toward direction: Direction, tiles: [WindowID: Rect]) -> WindowID? {
        guard let from = tiles[source] else { return nil }
        var best: (id: WindowID, distance: Int, overlap: Int)?
        for (id, rect) in tiles where id != source {
            let distance: Int
            switch direction {
            case .left: distance = from.minX - rect.maxX
            case .right: distance = rect.minX - from.maxX
            case .up: distance = from.minY - rect.maxY
            case .down: distance = rect.minY - from.maxY
            }
            guard distance >= 0 else { continue }
            let overlap = direction.axis == .horizontal
                ? min(from.maxY, rect.maxY) - max(from.minY, rect.minY)
                : min(from.maxX, rect.maxX) - max(from.minX, rect.minX)
            guard overlap > 0 else { continue }
            if let current = best {
                if distance < current.distance
                    || (distance == current.distance && overlap > current.overlap)
                    || (distance == current.distance && overlap == current.overlap && id < current.id) {
                    best = (id, distance, overlap)
                }
            } else {
                best = (id, distance, overlap)
            }
        }
        return best?.id
    }

    /// Where directional focus goes. Geometry works while tiles sit side by side; in monocle and
    /// in accordions the tiles overlap, so there is no "left of", and focus walks the tree order
    /// instead (AeroSpace's behaviour): left/up is the previous window, right/down the next.
    public static func focusTarget(
        from source: WindowID, toward direction: Direction, in workspace: Workspace,
        area: Rect, facts: [WindowID: WindowFacts], settings: WorldSettings
    ) -> WindowID? {
        let order = workspace.root.windows
        if workspace.layout == .monocle { return step(order, from: source, forward: direction.isForward) }

        let primary = Solver.primaryAxis(for: Renderer.tilingArea(area, settings: settings))
        // An accordion running along the direction: its siblings, in order.
        if let path = workspace.root.path(to: source), let parent = workspace.root.container(at: Array(path.dropLast())),
           parent.kind == .accordion, parent.axis.resolve(primary: primary) == direction.axis,
           let target = step(parent.windows, from: source, forward: direction.isForward) {
            return target
        }
        let plan = Renderer.plan(for: workspace, area: area, facts: facts, settings: settings)
        if let target = neighbor(of: source, toward: direction, tiles: plan.tiles) { return target }
        // Overflowed containers are drawn overlapping too: fall back to the tree order among the
        // windows that overlap the source.
        guard let tile = plan.tiles[source] else { return nil }
        let overlapping = order.filter { $0 == source || plan.tiles[$0].map { $0.intersects(tile) } ?? false }
        guard overlapping.count > 1 else { return nil }
        return step(overlapping, from: source, forward: direction.isForward)
    }

    static func step(_ order: [WindowID], from source: WindowID, forward: Bool) -> WindowID? {
        guard let index = order.firstIndex(of: source) else { return nil }
        let next = forward ? index + 1 : index - 1
        return order.indices.contains(next) ? order[next] : nil
    }
}
