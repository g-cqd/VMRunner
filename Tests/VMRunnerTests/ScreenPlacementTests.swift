import CoreGraphics
import Testing

@testable import VMRunner
@testable import VirtioGPU

/// Where the picture and the cursor sit in the view: the biggest fit with the picture's aspect ratio, centered.
struct ScreenPlacementTests {
    private let display = CGSize(width: 1280, height: 800)

    private func cursor(x: UInt32, y: UInt32, hot: UInt32 = 0, side: UInt32 = 64) -> CursorState {
        let picture = ScanoutUpdate(width: side, height: side, format: .b8g8r8a8, pixels: [])
        return CursorState(x: x, y: y, hotX: hot, hotY: hot, picture: picture, pictureGeneration: 1)
    }

    @Test
    func aPictureInAViewOfItsOwnSizeFillsIt() {
        #expect(ScreenPlacement.pictureRect(picture: display, in: display) == CGRect(x: 0, y: 0, width: 1280, height: 800))
    }

    @Test
    func aPictureInATallerViewIsCenteredWithBarsAboveAndBelow() {
        let rect = ScreenPlacement.pictureRect(picture: display, in: CGSize(width: 1000, height: 1000))
        #expect(rect == CGRect(x: 0, y: 187.5, width: 1000, height: 625))
    }

    @Test
    func aPictureInAWiderViewIsCenteredWithBarsAtTheSides() {
        let rect = ScreenPlacement.pictureRect(picture: display, in: CGSize(width: 2000, height: 800))
        #expect(rect == CGRect(x: 360, y: 0, width: 1280, height: 800))
    }

    @Test(arguments: [CGSize.zero, CGSize(width: 0, height: 10), CGSize(width: 10, height: 0)])
    func anEmptySizeGivesNoRectangle(empty: CGSize) {
        #expect(ScreenPlacement.pictureRect(picture: empty, in: display) == .zero)
        #expect(ScreenPlacement.pictureRect(picture: display, in: empty) == .zero)
        #expect(ScreenPlacement.cursorRect(cursor(x: 1, y: 1), picture: empty, in: display) == .zero)
    }

    @Test
    func theCursorsHotSpotSitsOnItsPosition() {
        let rect = ScreenPlacement.cursorRect(cursor(x: 100, y: 50, hot: 3), picture: display, in: display)
        #expect(rect == CGRect(x: 97, y: 47, width: 64, height: 64))
    }

    @Test
    func theCursorScalesWithThePictureAndFollowsItsBars() {
        let half = ScreenPlacement.cursorRect(cursor(x: 100, y: 50, hot: 4), picture: display, in: CGSize(width: 640, height: 400))
        #expect(half == CGRect(x: 48, y: 23, width: 32, height: 32))
        let barred = ScreenPlacement.cursorRect(cursor(x: 0, y: 0), picture: display, in: CGSize(width: 1000, height: 1000))
        #expect(barred == CGRect(x: 0, y: 187.5, width: 50, height: 50))
    }

    @Test
    func aCursorWithoutAPictureHasNoRectangle() {
        var hidden = cursor(x: 5, y: 5)
        hidden.picture = nil
        #expect(ScreenPlacement.cursorRect(hidden, picture: display, in: display) == .zero)
    }
}
