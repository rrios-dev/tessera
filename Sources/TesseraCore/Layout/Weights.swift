/// Child weights in parts per million. They always sum to exactly `Weights.total`.
///
/// Weights express the user's intent (how the space is shared) and never change as a side
/// effect of solving: only explicit resizes, balancing and tree edits touch them.
public enum Weights {
    public static let total = 1_000_000

    /// The smallest weight a child may hold: 5 %, or 1/(2n) when there are many children.
    public static func floor(count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(50_000, total / (2 * count))
    }

    /// Splits `amount` proportionally to `shares` using the largest-remainder method.
    /// The parts always sum to `amount`; ties go to the lower index.
    public static func apportion(_ amount: Int, shares: [Int]) -> [Int] {
        guard !shares.isEmpty else { return [] }
        let sum = shares.reduce(0, +)
        guard sum > 0 else { return apportion(amount, shares: Array(repeating: 1, count: shares.count)) }

        var parts = [Int](repeating: 0, count: shares.count)
        var remainders: [(index: Int, remainder: Int)] = []
        remainders.reserveCapacity(shares.count)
        var assigned = 0
        for (index, share) in shares.enumerated() {
            let (quotient, remainder) = (amount * share).quotientAndRemainder(dividingBy: sum)
            parts[index] = quotient
            assigned += quotient
            remainders.append((index, remainder))
        }
        var leftover = amount - assigned
        remainders.sort { $0.remainder != $1.remainder ? $0.remainder > $1.remainder : $0.index < $1.index }
        var cursor = 0
        while leftover > 0 {
            parts[remainders[cursor % remainders.count].index] += 1
            leftover -= 1
            cursor += 1
        }
        return parts
    }

    public static func balanced(count: Int) -> [Int] {
        apportion(total, shares: Array(repeating: 1, count: count))
    }

    /// Inserts a child at `index` with weight 1/n and scales the others by (n−1)/n.
    public static func inserting(into weights: [Int], at index: Int) -> [Int] {
        let n = weights.count + 1
        var shares = weights.map { $0 * (n - 1) }
        shares.insert(total, at: min(max(index, 0), weights.count))
        return applyingFloor(apportion(total, shares: shares))
    }

    /// Removes the child at `index` and gives its share to the others in proportion.
    public static func removing(from weights: [Int], at index: Int) -> [Int] {
        var remaining = weights
        remaining.remove(at: index)
        guard !remaining.isEmpty else { return [] }
        return applyingFloor(apportion(total, shares: remaining))
    }

    /// Moves `delta` ppm from `donor` to `receiver`, keeping both at or above the floor.
    public static func transferring(_ weights: [Int], delta: Int, from donor: Int, to receiver: Int) -> [Int] {
        guard weights.indices.contains(donor), weights.indices.contains(receiver), donor != receiver else { return weights }
        let minimum = floor(count: weights.count)
        let moved: Int
        if delta >= 0 {
            moved = min(delta, max(0, weights[donor] - minimum))
        } else {
            moved = -min(-delta, max(0, weights[receiver] - minimum))
        }
        var result = weights
        result[donor] -= moved
        result[receiver] += moved
        return result
    }

    /// Raises every weight below the floor to it and takes the difference from the others in
    /// proportion to how far they sit above the floor ("water filling").
    public static func applyingFloor(_ weights: [Int]) -> [Int] {
        let minimum = floor(count: weights.count)
        let deficit = weights.reduce(0) { $0 + max(0, minimum - $1) }
        guard deficit > 0 else { return weights }
        let excess = weights.map { max(0, $0 - minimum) }
        let taken = apportion(deficit, shares: excess)
        return weights.indices.map { index in
            weights[index] < minimum ? minimum : weights[index] - taken[index]
        }
    }
}
