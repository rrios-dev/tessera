import Testing
@testable import TesseraCore

struct GeometryTests {
    @Test func intersectionIsHalfOpen() {
        let a = Rect(x: 0, y: 0, width: 10, height: 10)
        let touching = Rect(x: 10, y: 0, width: 10, height: 10)
        #expect(a.intersection(touching) == nil)
        #expect(a.intersection(Rect(x: 5, y: 5, width: 10, height: 10)) == Rect(x: 5, y: 5, width: 5, height: 5))
    }

    @Test func containment() {
        let area = Rect(x: 0, y: 30, width: 1080, height: 2448)
        #expect(area.contains(Rect(x: 0, y: 30, width: 540, height: 2448)))
        #expect(!area.contains(Rect(x: 0, y: 29, width: 540, height: 100)))
        #expect(area.contains(Point(x: 1079, y: 2477)))
        #expect(!area.contains(Point(x: 1080, y: 100)))
    }

    @Test func insetShrinksEveryEdge() {
        let frame = Rect(x: 0, y: 0, width: 1080, height: 2560)
        let visible = frame.inset(by: Insets(top: 30, left: 0, bottom: 82, right: 0))
        #expect(visible == Rect(x: 0, y: 30, width: 1080, height: 2448))
    }

    @Test func portraitDetection() {
        let display = DisplayInfo(
            displayID: 5, uuid: nil, name: "LG", vendor: 0, model: 0, serial: 0, unitNumber: 0,
            isMain: true, isBuiltin: false, mirrorsDisplayID: nil, rotationDegrees: 270,
            frame: Rect(x: 0, y: 0, width: 1080, height: 2560),
            visibleFrame: Rect(x: 0, y: 30, width: 1080, height: 2448),
            pixelWidth: 1080, pixelHeight: 2560, backingScale: 1, refreshHz: 75,
            safeAreaInsets: .zero, menuBarHeight: 30
        )
        #expect(display.isPortrait)
    }

    @Test func fullScreenSpacesAreNotDesktops() {
        let spaces = DisplaySpaces(displayIdentifier: "Main", spaceTypes: [0, 4], currentSpaceType: 4)
        #expect(spaces.desktopSpaceCount == 1)
    }
}
