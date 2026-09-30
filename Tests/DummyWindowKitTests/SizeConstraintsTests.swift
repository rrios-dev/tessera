import Foundation
import Testing
import TesseraCore
@testable import DummyWindowKit

struct SizeConstraintsTests {
    let origin = Rect(x: 0, y: 0, width: 100, height: 100)

    @Test func clampsToMinimumAndMaximum() {
        let spec = WindowSpec(id: "a", frame: origin, minSize: Size(width: 400, height: 300), maxSize: Size(width: 900, height: 700))
        #expect(SizeConstraints.accepted(Size(width: 200, height: 1000), spec: spec) == Size(width: 400, height: 700))
    }

    @Test func snapsToQuantumAnchoredAtMinimum() {
        // A terminal: 7x17 cells over a 60x40 minimum.
        let spec = WindowSpec(id: "t", frame: origin, minSize: Size(width: 60, height: 40), quantum: Size(width: 7, height: 17))
        let accepted = SizeConstraints.accepted(Size(width: 540, height: 1250), spec: spec)
        #expect(accepted == Size(width: 60 + 68 * 7, height: 40 + 71 * 17))
        #expect(540 - accepted.width < 7)
        #expect(1250 - accepted.height < 17)
    }

    @Test func quantumNeverExceedsMaximum() {
        let spec = WindowSpec(id: "t", frame: origin, maxSize: Size(width: 100, height: 100), quantum: Size(width: 30, height: 30))
        #expect(SizeConstraints.accepted(Size(width: 500, height: 500), spec: spec) == Size(width: 90, height: 90))
    }

    @Test func aspectRatioDerivesHeightFromWidth() {
        let spec = WindowSpec(id: "sim", frame: origin, aspectRatio: Size(width: 9, height: 19))
        #expect(SizeConstraints.accepted(Size(width: 540, height: 2000), spec: spec) == Size(width: 540, height: 1140))
    }

    @Test func requestRoundTripsThroughJSON() throws {
        let request = Request(
            op: .open,
            spec: WindowSpec(id: "a", frame: origin, minSize: Size(width: 1, height: 2),
                             selfResize: SelfResize(afterMilliseconds: 1000, size: Size(width: 3, height: 4)))
        )
        let data = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(Request.self, from: data) == request)
    }

    @Test func rigidDefaultsToFalseWhenOmitted() throws {
        let json = #"{"op":"open","spec":{"id":"a","frame":{"x":0,"y":0,"width":10,"height":10}}}"#
        let request = try JSONDecoder().decode(Request.self, from: Data(json.utf8))
        #expect(request.spec?.rigid == false)
    }
}
