import Testing
@testable import TesseraCore

struct TreeAndWeightsTests {
    @Test func insertingKeepsTheSumExact() {
        var weights: [Int] = []
        for index in 0..<50 {
            weights = Weights.inserting(into: weights, at: index % (weights.count + 1))
            #expect(weights.reduce(0, +) == Weights.total)
            #expect(weights.allSatisfy { $0 >= Weights.floor(count: weights.count) })
        }
        // The counterexample from the audit: truncation lost 2 ppm here.
        let three = Weights.balanced(count: 3)
        #expect(Weights.inserting(into: three, at: 3).reduce(0, +) == Weights.total)
    }

    @Test func floorHoldsAfterInsertingNextToASmallChild() {
        let weights = Weights.inserting(into: [50_000, 950_000], at: 2)
        #expect(weights.reduce(0, +) == Weights.total)
        #expect(weights.allSatisfy { $0 >= 50_000 })
    }

    @Test func removingRedistributesProportionally() {
        let weights = Weights.removing(from: [500_000, 250_000, 250_000], at: 0)
        #expect(weights == [500_000, 500_000])
    }

    @Test func transferRespectsTheFloor() {
        let weights = Weights.transferring([100_000, 900_000], delta: 90_000, from: 0, to: 1)
        #expect(weights == [50_000, 950_000])
    }

    @Test func normalisationIsIdempotentAndKeepsEveryWindowOnce() {
        for seed in 0..<2_000 {
            var generator = TreeGenerator(seed: UInt64(seed))
            let root = generator.container(depth: 0)
            let once = root.normalized()
            #expect(once.normalized() == once, "seed \(seed)")
            #expect(once.windows.sorted() == root.windows.sorted(), "seed \(seed)")
            #expect(once.weights.reduce(0, +) == Weights.total)
        }
    }

    @Test func removingTheLastWindowOfANestedContainerDropsIt() {
        var root = Container(children: [.window(1), .container(Container(axis: .secondary, children: [.window(2)]))])
        root.removeWindow(2)
        #expect(root.children == [.window(1)])
        #expect(root.weights == [Weights.total])
    }
}
