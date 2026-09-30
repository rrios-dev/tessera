/// A window as the window server identifies it (`CGWindowID`).
public typealias WindowID = UInt32

public enum Axis: String, Codable, Sendable, Hashable {
    case horizontal, vertical

    public var opposite: Axis { self == .horizontal ? .vertical : .horizontal }
}

/// An axis resolved at every solve, so a workspace moved to a portrait monitor turns its
/// columns into rows without touching the tree.
public enum AxisSpec: Codable, Sendable, Hashable {
    /// Horizontal on a landscape area, vertical on a portrait one.
    case primary
    case secondary
    case fixed(Axis)

    public func resolve(primary: Axis) -> Axis {
        switch self {
        case .primary: primary
        case .secondary: primary.opposite
        case .fixed(let axis): axis
        }
    }

    public var flipped: AxisSpec {
        switch self {
        case .primary: .secondary
        case .secondary: .primary
        case .fixed(let axis): .fixed(axis.opposite)
        }
    }
}

public enum ContainerKind: String, Codable, Sendable, Hashable {
    case tiles, accordion
}

public indirect enum Node: Codable, Sendable, Hashable {
    case window(WindowID)
    case container(Container)

    public var windows: [WindowID] {
        switch self {
        case .window(let id): [id]
        case .container(let container): container.windows
        }
    }

    public func contains(_ id: WindowID) -> Bool {
        switch self {
        case .window(let own): own == id
        case .container(let container): container.contains(id)
        }
    }
}

public struct Container: Codable, Sendable, Hashable {
    public var axis: AxisSpec
    public var kind: ContainerKind
    public private(set) var children: [Node]
    /// Parts per million, parallel to `children`, summing to `Weights.total`.
    public private(set) var weights: [Int]

    public init(axis: AxisSpec = .primary, kind: ContainerKind = .tiles, children: [Node] = [], weights: [Int]? = nil) {
        self.axis = axis
        self.kind = kind
        self.children = children
        self.weights = weights ?? Weights.balanced(count: children.count)
        precondition(self.weights.count == children.count, "one weight per child")
    }

    public var isEmpty: Bool { children.isEmpty }
    public var windows: [WindowID] { children.flatMap(\.windows) }
    public func contains(_ id: WindowID) -> Bool { children.contains { $0.contains(id) } }

    // MARK: - Editing

    public mutating func insert(_ node: Node, at index: Int) {
        let position = min(max(index, 0), children.count)
        weights = Weights.inserting(into: weights, at: position)
        children.insert(node, at: position)
    }

    public mutating func remove(at index: Int) -> Node {
        weights = Weights.removing(from: weights, at: index)
        return children.remove(at: index)
    }

    public mutating func replace(at index: Int, with node: Node) {
        children[index] = node
    }

    public mutating func setWeights(_ newWeights: [Int]) {
        precondition(newWeights.count == children.count && newWeights.reduce(0, +) == Weights.total)
        weights = newWeights
    }

    public mutating func swapChildren(_ a: Int, _ b: Int) {
        children.swapAt(a, b)
    }

    public mutating func balance() {
        weights = Weights.balanced(count: children.count)
        children = children.map { child in
            guard case .container(var nested) = child else { return child }
            nested.balance()
            return .container(nested)
        }
    }

    /// Removes a window wherever it is. Empty containers disappear with it.
    @discardableResult
    public mutating func removeWindow(_ id: WindowID) -> Bool {
        for index in children.indices {
            switch children[index] {
            case .window(let own) where own == id:
                _ = remove(at: index)
                return true
            case .container(var nested) where nested.contains(id):
                nested.removeWindow(id)
                if nested.isEmpty { _ = remove(at: index) } else { children[index] = .container(nested) }
                return true
            default:
                continue
            }
        }
        return false
    }

    /// Path of child indices from this container to the window.
    public func path(to id: WindowID) -> [Int]? {
        for (index, child) in children.enumerated() {
            switch child {
            case .window(let own) where own == id:
                return [index]
            case .container(let nested):
                if let rest = nested.path(to: id) { return [index] + rest }
            default:
                continue
            }
        }
        return nil
    }

    public func container(at path: [Int]) -> Container? {
        guard let first = path.first else { return self }
        guard children.indices.contains(first), case .container(let nested) = children[first] else { return nil }
        return nested.container(at: Array(path.dropFirst()))
    }

    /// Applies `body` to the container at `path` (an empty path is this container).
    public mutating func modifyContainer(at path: [Int], _ body: (inout Container) -> Void) {
        guard let first = path.first else {
            body(&self)
            return
        }
        guard case .container(var nested) = children[first] else { return }
        nested.modifyContainer(at: Array(path.dropFirst()), body)
        children[first] = .container(nested)
    }

    // MARK: - Normalisation

    /// Flattens single-child containers, splices nested containers that share their
    /// parent's axis and kind, and drops empty ones. Idempotent. The receiver keeps its own
    /// axis and kind even when it ends up with a single child.
    public func normalized() -> Container {
        var nodes: [Node] = []
        var newWeights: [Int] = []

        func append(_ node: Node, weight: Int) {
            guard case .container(let nested) = node else {
                nodes.append(node)
                newWeights.append(weight)
                return
            }
            let child = nested.normalized()
            if child.isEmpty { return }
            if child.children.count == 1 {
                append(child.children[0], weight: weight)
            } else if child.axis == axis && child.kind == kind {
                for (grandchild, share) in zip(child.children, Weights.apportion(weight, shares: child.weights)) {
                    append(grandchild, weight: share)
                }
            } else {
                nodes.append(.container(child))
                newWeights.append(weight)
            }
        }

        for (child, weight) in zip(children, weights) { append(child, weight: weight) }
        guard !nodes.isEmpty else { return Container(axis: axis, kind: kind) }
        let exact = newWeights.reduce(0, +) == Weights.total
            ? newWeights
            : Weights.apportion(Weights.total, shares: newWeights)
        return Container(axis: axis, kind: kind, children: nodes, weights: Weights.applyingFloor(exact))
    }
}
