/// The only place a `World` changes. Pure: same world, event and area, same result.
public enum Reducer {
    /// - Parameter area: the usable area of the monitor showing the active Space, needed by
    ///   commands that reason about geometry (focus, move, resize).
    public static func reduce(_ world: World, _ event: Event, area: Rect) -> World {
        var next = world
        switch event {
        case .spacesChanged(let descriptors, let active):
            next.applySpaces(descriptors, active: active)
        case .windowObserved(let observation):
            next.observe(observation)
        case .windowGone(let id):
            next.forget(id)
        case .focusChanged(let id):
            next.focus(id)
        case .factsLearned(let id, let facts):
            if next.windows[id] != nil { next.facts[id] = facts }
        case .command(let command):
            next.run(command, area: area)
        }
        return next
    }
}

extension World {
    // MARK: - Spaces

    mutating func applySpaces(_ descriptors: [SpaceDescriptor], active: SpaceID?) {
        for descriptor in descriptors {
            if spaces[descriptor.id] == nil {
                spaces[descriptor.id] = SpaceState(id: descriptor.id, kind: descriptor.kind, layout: settings.defaultLayout)
            } else {
                spaces[descriptor.id]?.kind = descriptor.kind
            }
        }
        // A vanished Space keeps its windows until macOS reports where they went.
        let live = Set(descriptors.map(\.id))
        for id in spaces.keys where !live.contains(id) {
            let hasWindows = windows.values.contains { $0.space == id }
            if !hasWindows { spaces[id] = nil }
        }
        if let active { activeSpace = active }
    }

    mutating func ensureSpace(_ id: SpaceID, kind: SpaceKind) {
        if spaces[id] == nil { spaces[id] = SpaceState(id: id, kind: kind, layout: settings.defaultLayout) }
    }

    // MARK: - Windows

    mutating func observe(_ observation: WindowObservation) {
        let space = observation.space ?? windows[observation.id]?.space ?? activeSpace ?? 0
        let userFloating = windows[observation.id]?.userFloating
        let floats = userFloating ?? (observation.prefersFloating || observation.isOnAllSpaces)
        let mode: WindowMode
        if observation.isNativeFullscreen {
            mode = .nativeFullscreen
        } else if observation.isMinimized {
            mode = .minimized
        } else if observation.isAppHidden {
            mode = .appHidden
        } else if floats {
            mode = .floating
        } else {
            mode = .tiled
        }
        ensureSpace(space, kind: observation.isNativeFullscreen ? .fullscreen : .desktop)

        if let existing = windows[observation.id] {
            guard existing.space != space || existing.mode != mode else { return }
            detach(existing.id)
            let workspace = existing.space == space ? existing.workspace : spaces[space]!.activeWorkspace
            if existing.space != space || existing.workspace != workspace {
                // Moved to another Space: it leaves the old workspace's focus history, and the old
                // workspace disappears if that emptied it (I8, I15).
                modifyWorkspace(space: existing.space, name: existing.workspace) { $0.mru.removeAll { $0 == existing.id } }
                windows[existing.id]?.space = space
                windows[existing.id]?.workspace = workspace
                pruneEmptyWorkspaces(in: existing.space)
            }
            place(WindowRecord(id: observation.id, pid: observation.pid, space: space, workspace: workspace, mode: mode, userFloating: userFloating))
            if focused == existing.id, existing.space != space {
                modifyWorkspace(space: space, name: workspace) { $0.mru.insert(existing.id, at: 0) }
            }
        } else {
            let workspace = spaces[space]!.activeWorkspace
            place(WindowRecord(id: observation.id, pid: observation.pid, space: space, workspace: workspace, mode: mode))
        }
    }

    /// Puts a record into its workspace: tiled windows go right after the focused one.
    mutating func place(_ record: WindowRecord) {
        windows[record.id] = record
        let focusedHere = focused.flatMap { windows[$0] }.flatMap { $0.space == record.space && $0.workspace == record.workspace ? $0.id : nil }
        modifyWorkspace(space: record.space, name: record.workspace) { workspace in
            switch record.mode {
            case .tiled:
                if let anchor = focusedHere, let path = workspace.root.path(to: anchor) {
                    let parentPath = Array(path.dropLast())
                    workspace.root.modifyContainer(at: parentPath) { $0.insert(.window(record.id), at: path.last! + 1) }
                } else {
                    workspace.root.insert(.window(record.id), at: workspace.root.children.count)
                }
                workspace.root = workspace.root.normalized()
            case .floating:
                workspace.floating.insert(record.id, at: 0)
            case .nativeFullscreen, .minimized, .appHidden:
                break
            }
        }
    }

    /// Takes a window out of its tree or floating list without forgetting it.
    mutating func detach(_ id: WindowID) {
        guard let record = windows[id] else { return }
        modifyWorkspace(space: record.space, name: record.workspace) { workspace in
            workspace.root.removeWindow(id)
            workspace.root = workspace.root.normalized()
            workspace.floating.removeAll { $0 == id }
            if workspace.zoomed == id { workspace.zoomed = nil }
        }
    }

    mutating func forget(_ id: WindowID) {
        guard let record = windows[id] else { return }
        detach(id)
        modifyWorkspace(space: record.space, name: record.workspace) { $0.mru.removeAll { $0 == id } }
        windows[id] = nil
        facts[id] = nil
        if focused == id {
            focused = spaces[record.space]?.workspace(named: record.workspace)?.mru.first
        }
        pruneEmptyWorkspaces(in: record.space)
    }

    // MARK: - Focus

    mutating func focus(_ id: WindowID?) {
        focused = id
        guard let id, let record = windows[id] else { return }
        modifyWorkspace(space: record.space, name: record.workspace) { workspace in
            workspace.mru.removeAll { $0 == id }
            workspace.mru.insert(id, at: 0)
            // Tessera full screen belongs to the workspace: it follows the focus to another tiled window.
            if workspace.zoomed != nil, workspace.root.contains(id) { workspace.zoomed = id }
        }
        // Focus that lands on a hidden workspace (Cmd-Tab, Dock) brings that workspace forward.
        if let space = spaces[record.space], space.activeWorkspace != record.workspace {
            switchWorkspace(in: record.space, to: record.workspace)
        }
    }

    // MARK: - Commands

    mutating func run(_ command: Command, area: Rect) {
        if case .focusWindow(let id) = command {
            if windows[id] != nil { focus(id) }
            return
        }
        if case .insertWindow(let id, let anchor, let after) = command {
            guard id != anchor, var record = windows[id], let target = windows[anchor], target.mode == .tiled,
                  record.mode == .tiled || record.mode == .floating else { return }
            detach(id)
            modifyWorkspace(space: record.space, name: record.workspace) { $0.mru.removeAll { $0 == id } }
            let source = record.space
            record.space = target.space
            record.workspace = target.workspace
            record.mode = .tiled
            record.userFloating = false
            windows[id] = record
            modifyWorkspace(space: target.space, name: target.workspace) { workspace in
                guard let path = workspace.root.path(to: anchor) else { return }
                workspace.root.modifyContainer(at: Array(path.dropLast())) { $0.insert(.window(id), at: path.last! + (after ? 1 : 0)) }
                workspace.root = workspace.root.normalized()
            }
            pruneEmptyWorkspaces(in: source)
            focus(id)
            return
        }
        if case .setFloating(let id, let floating) = command {
            guard var record = windows[id] else { return }
            record.userFloating = floating
            let wanted: WindowMode = floating ? .floating : .tiled
            guard record.mode == .tiled || record.mode == .floating, record.mode != wanted else {
                windows[id] = record
                return
            }
            detach(id)
            record.mode = wanted
            place(record)
            return
        }
        guard let spaceID = activeSpace, let space = spaces[spaceID], space.kind == .desktop else { return }
        let workspaceName = space.activeWorkspace
        let focusedRecord = focused.flatMap { windows[$0] }.flatMap { $0.space == spaceID && $0.workspace == workspaceName ? $0 : nil }

        switch command {
        case .focusWindow, .setFloating, .insertWindow:
            return

        case .workspace(let name):
            switchWorkspace(in: spaceID, to: name)
            focused = spaces[spaceID]?.workspace(named: name)?.mru.first

        case .workspaceBackAndForth:
            if let previous = space.previousWorkspace {
                switchWorkspace(in: spaceID, to: previous)
                focused = spaces[spaceID]?.workspace(named: previous)?.mru.first
            }

        case .moveNodeToWorkspace(let name):
            guard let record = focusedRecord, name != workspaceName else { return }
            spaces[spaceID]?.ensureWorkspace(named: name, layout: settings.defaultLayout)
            detach(record.id)
            modifyWorkspace(space: spaceID, name: workspaceName) { $0.mru.removeAll { $0 == record.id } }
            var moved = record
            moved.workspace = name
            let previousFocus = focused
            focused = nil
            place(moved)
            modifyWorkspace(space: spaceID, name: name) { $0.mru.insert(record.id, at: 0) }
            if previousFocus == record.id {
                // Focus stays in the source workspace: the most recent window, else any window.
                // Leaving it empty would let macOS's stale "focused" report drag the view after
                // the moved window.
                let source = spaces[spaceID]?.workspace(named: workspaceName)
                focused = source?.mru.first ?? source?.root.windows.first ?? source?.floating.first
                if let next = focused {
                    modifyWorkspace(space: spaceID, name: workspaceName) { workspace in
                        workspace.mru.removeAll { $0 == next }
                        workspace.mru.insert(next, at: 0)
                    }
                }
            } else {
                focused = previousFocus
            }

        case .focus(let direction):
            guard let record = focusedRecord, let workspace = spaces[spaceID]?.workspace(named: workspaceName) else { return }
            if let target = Navigation.focusTarget(from: record.id, toward: direction, in: workspace, area: area, facts: facts, settings: settings) {
                focus(target)
            }

        case .move(let direction):
            guard let record = focusedRecord, record.mode == .tiled else { return }
            moveTiled(record.id, direction: direction, space: spaceID, workspace: workspaceName, area: area)

        case .layout(let mode):
            modifyWorkspace(space: spaceID, name: workspaceName) { workspace in
                switch mode {
                case .monocle:
                    workspace.layout = .monocle
                case .tiles, .accordion:
                    workspace.layout = mode
                    let kind: ContainerKind = mode == .tiles ? .tiles : .accordion
                    if let id = focusedRecord?.id, let path = workspace.root.path(to: id) {
                        workspace.root.modifyContainer(at: Array(path.dropLast())) { $0.kind = kind }
                    } else {
                        workspace.root.kind = kind
                    }
                    workspace.root = workspace.root.normalized()
                }
            }

        case .toggleOrientation:
            modifyWorkspace(space: spaceID, name: workspaceName) { workspace in
                if let id = focusedRecord?.id, let path = workspace.root.path(to: id) {
                    workspace.root.modifyContainer(at: Array(path.dropLast())) { $0.axis = $0.axis.flipped }
                } else {
                    workspace.root.axis = workspace.root.axis.flipped
                }
                workspace.root = workspace.root.normalized()
            }

        case .toggleFloating:
            guard var record = focusedRecord, record.mode == .tiled || record.mode == .floating else { return }
            detach(record.id)
            record.mode = record.mode == .tiled ? .floating : .tiled
            record.userFloating = record.mode == .floating
            place(record)

        case .toggleFullscreen:
            // Always a toggle: leaves full screen whichever window holds it, else enters it.
            if spaces[spaceID]?.workspace(named: workspaceName)?.zoomed != nil {
                modifyWorkspace(space: spaceID, name: workspaceName) { $0.zoomed = nil }
                return
            }
            guard let record = focusedRecord, record.mode == .tiled else { return }
            modifyWorkspace(space: spaceID, name: workspaceName) { $0.zoomed = record.id }

        case .swapWindows(let a, let b):
            guard a != b, let first = windows[a], let second = windows[b],
                  first.space == spaceID, second.space == spaceID,
                  first.workspace == workspaceName, second.workspace == workspaceName,
                  first.mode == .tiled, second.mode == .tiled else { return }
            modifyWorkspace(space: spaceID, name: workspaceName) { workspace in
                guard let from = workspace.root.path(to: a), let to = workspace.root.path(to: b) else { return }
                workspace.root.replace(path: from, with: .window(b))
                workspace.root.replace(path: to, with: .window(a))
            }

        case .resizeWindow(let id, let frame):
            guard let record = windows[id], record.space == spaceID, record.workspace == workspaceName,
                  record.mode == .tiled else { return }
            resizeTiled(id, toward: frame, space: spaceID, workspace: workspaceName, area: area)

        case .balanceSizes:
            modifyWorkspace(space: spaceID, name: workspaceName) { $0.root.balance() }

        case .gatherWindows:
            for other in space.workspaces where other.name != workspaceName {
                for id in other.root.windows + other.floating {
                    guard var record = windows[id] else { continue }
                    detach(id)
                    modifyWorkspace(space: spaceID, name: other.name) { $0.mru.removeAll { $0 == id } }
                    record.workspace = workspaceName
                    place(record)
                }
                // Minimised or hidden windows of that group come along too.
                for id in windows.keys where windows[id]?.space == spaceID && windows[id]?.workspace == other.name {
                    windows[id]?.workspace = workspaceName
                }
            }
            modifyWorkspace(space: spaceID, name: workspaceName) { $0.zoomed = nil }
            spaces[spaceID]?.previousWorkspace = nil
            pruneEmptyWorkspaces(in: spaceID)

        case .resize(let dimension, let points):
            guard let record = focusedRecord, record.mode == .tiled else { return }
            let bounded = min(max(points, -Command.maxResize), Command.maxResize)
            resizeTiled(record.id, dimension: dimension, points: bounded, space: spaceID, workspace: workspaceName, area: area)
        }
    }

    mutating func switchWorkspace(in spaceID: SpaceID, to name: String) {
        guard var space = spaces[spaceID], space.activeWorkspace != name else { return }
        space.ensureWorkspace(named: name, layout: settings.defaultLayout)
        space.previousWorkspace = space.activeWorkspace
        space.activeWorkspace = name
        spaces[spaceID] = space
        pruneEmptyWorkspaces(in: spaceID)
    }

    /// Empty workspaces that are not shown disappear, like AeroSpace's non-persistent ones.
    mutating func pruneEmptyWorkspaces(in spaceID: SpaceID) {
        guard var space = spaces[spaceID] else { return }
        space.workspaces.removeAll { workspace in
            workspace.name != space.activeWorkspace && workspace.name != space.previousWorkspace
                && workspace.isEmpty && !windows.values.contains { $0.space == spaceID && $0.workspace == workspace.name }
        }
        spaces[spaceID] = space
    }

    /// Swap with the neighbour in `direction`; with no neighbour, move to that edge of the
    /// workspace, splitting the root if its axis does not run that way.
    mutating func moveTiled(_ id: WindowID, direction: Direction, space: SpaceID, workspace name: String, area: Rect) {
        guard let workspace = spaces[space]?.workspace(named: name) else { return }
        let plan = Renderer.plan(for: workspace, area: area, facts: facts, settings: settings)
        let primary = Solver.primaryAxis(for: Renderer.tilingArea(area, settings: settings))

        modifyWorkspace(space: space, name: name) { workspace in
            if let target = Navigation.neighbor(of: id, toward: direction, tiles: plan.tiles),
               let from = workspace.root.path(to: id), let to = workspace.root.path(to: target) {
                workspace.root.replace(path: from, with: .window(target))
                workspace.root.replace(path: to, with: .window(id))
                return
            }
            guard workspace.root.windows.count > 1 else { return }
            workspace.root.removeWindow(id)
            if workspace.root.axis.resolve(primary: primary) != direction.axis {
                let wrapperAxis: AxisSpec = direction.axis == primary ? .primary : .secondary
                var inner = workspace.root
                inner.axis = wrapperAxis.flipped
                workspace.root = Container(axis: wrapperAxis, kind: .tiles, children: [.container(inner)])
            }
            workspace.root.insert(.window(id), at: direction.isForward ? workspace.root.children.count : 0)
            workspace.root = workspace.root.normalized()
        }
    }

    /// Moves `points` of length between the window's container slot and its neighbour along
    /// the nearest ancestor that runs in the resized dimension.
    mutating func resizeTiled(_ id: WindowID, dimension: Dimension, points: Int, space: SpaceID, workspace name: String, area: Rect) {
        let tilingArea = Renderer.tilingArea(area, settings: settings)
        let primary = Solver.primaryAxis(for: tilingArea)
        modifyWorkspace(space: space, name: name) { workspace in
            guard var path = workspace.root.path(to: id) else { return }
            while !path.isEmpty {
                let index = path.removeLast()
                guard let container = workspace.root.container(at: path),
                      container.axis.resolve(primary: primary) == dimension.axis,
                      container.children.count > 1 else { continue }
                let length = dimension == .width ? tilingArea.width : tilingArea.height
                let delta = points * Weights.total / max(1, length)
                let neighbour = index + 1 < container.children.count ? index + 1 : index - 1
                workspace.root.modifyContainer(at: path) { container in
                    container.setWeights(Weights.transferring(container.weights, delta: -delta, from: index, to: neighbour))
                }
                return
            }
        }
    }
}

extension World {
    /// Turns a mouse resize into weights: for each dimension whose length changed, the edge the
    /// user dragged decides which neighbour gives or takes the space.
    mutating func resizeTiled(_ id: WindowID, toward frame: Rect, space: SpaceID, workspace name: String, area: Rect) {
        guard let workspace = spaces[space]?.workspace(named: name) else { return }
        let plan = Renderer.plan(for: workspace, area: area, facts: facts, settings: settings)
        guard let tile = plan.tiles[id] else { return }
        let primary = Solver.primaryAxis(for: Renderer.tilingArea(area, settings: settings))

        for axis in [Axis.horizontal, .vertical] {
            let raw = axis == .horizontal ? frame.width - tile.width : frame.height - tile.height
            let delta = min(max(raw, -Command.maxResize), Command.maxResize)
            guard abs(delta) >= 2 else { continue }
            let leadingMoved = axis == .horizontal ? frame.minX != tile.minX : frame.minY != tile.minY
            modifyWorkspace(space: space, name: name) { workspace in
                guard var path = workspace.root.path(to: id) else { return }
                while !path.isEmpty {
                    let index = path.removeLast()
                    guard let container = workspace.root.container(at: path),
                          container.axis.resolve(primary: primary) == axis, container.children.count > 1 else { continue }
                    let neighbour = leadingMoved ? index - 1 : index + 1
                    guard container.children.indices.contains(neighbour) else { continue }
                    let span = container.windows.compactMap { plan.tiles[$0] }
                        .reduce(0) { max($0, axis == .horizontal ? $1.maxX : $1.maxY) }
                        - container.windows.compactMap { plan.tiles[$0] }
                        .reduce(Int.max) { min($0, axis == .horizontal ? $1.minX : $1.minY) }
                    let ppm = delta * Weights.total / max(1, span)
                    workspace.root.modifyContainer(at: path) { container in
                        container.setWeights(Weights.transferring(container.weights, delta: ppm, from: neighbour, to: index))
                    }
                    return
                }
            }
        }
    }
}

extension Container {
    /// Replaces the node at `path` (a path to a leaf or a container).
    mutating func replace(path: [Int], with node: Node) {
        guard let last = path.last else { return }
        modifyContainer(at: Array(path.dropLast())) { $0.replace(at: last, with: node) }
    }
}
