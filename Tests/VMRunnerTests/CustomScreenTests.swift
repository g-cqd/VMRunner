import CoreGraphics
import Testing

@testable import VMRunner
@testable import VirtioGPU

/// What the window is given of the guest's drawing: the newest picture, and the cursor with the rules of its updates.
@MainActor
struct CustomScreenTests {
    private func picture(_ side: UInt32, fill: UInt8 = 0) -> ScanoutUpdate {
        ScanoutUpdate(width: side, height: side, format: .b8g8r8x8, pixels: Array(repeating: fill, count: Int(side * side) * 4))
    }

    private func screen() -> CustomScreen { CustomScreen(displaySize: CGSize(width: 1280, height: 800)) }

    @Test
    func aNewScreenHasNoPictureAndNoCursorAndTheSizeItWasGiven() {
        let screen = screen()
        #expect(screen.frame == nil && screen.cursor == nil)
        #expect(screen.displaySize == CGSize(width: 1280, height: 800))
    }

    @Test
    func theNewestPictureReplacesTheOneBefore() {
        let screen = screen()
        screen.show(picture(2, fill: 1))
        screen.show(picture(3, fill: 2))
        #expect(screen.frame == picture(3, fill: 2))
    }

    @Test
    func aMoveBeforeAnyImageGivesAPositionAndNoPicture() throws {
        let screen = screen()
        screen.show(CursorUpdate(x: 5, y: 6, hotX: 0, hotY: 0, image: .unchanged))
        let cursor = try #require(screen.cursor)
        #expect([cursor.x, cursor.y] == [5, 6] && cursor.picture == nil)
    }

    @Test
    func anUpdateSetsThePictureAndAMoveKeepsItWithItsHotSpot() throws {
        let screen = screen()
        screen.show(CursorUpdate(x: 10, y: 20, hotX: 3, hotY: 4, image: .shown(picture(64, fill: 9))))
        let first = try #require(screen.cursor)
        screen.show(CursorUpdate(x: 30, y: 40, hotX: 3, hotY: 4, image: .unchanged))
        let moved = try #require(screen.cursor)
        #expect(first.picture == picture(64, fill: 9) && moved.picture == first.picture)
        #expect([moved.x, moved.y, moved.hotX, moved.hotY] == [30, 40, 3, 4])
        #expect(moved.pictureGeneration == first.pictureGeneration, "a move leaves the converted copy valid")
    }

    @Test
    func aNewPictureOrAHideChangesTheGenerationAndAMoveAfterAHideStaysHidden() throws {
        let screen = screen()
        screen.show(CursorUpdate(x: 0, y: 0, hotX: 0, hotY: 0, image: .shown(picture(8))))
        let shown = try #require(screen.cursor?.pictureGeneration)
        screen.show(CursorUpdate(x: 0, y: 0, hotX: 0, hotY: 0, image: .shown(picture(8, fill: 1))))
        let replaced = try #require(screen.cursor?.pictureGeneration)
        screen.show(CursorUpdate(x: 0, y: 0, hotX: 0, hotY: 0, image: .hidden))
        let hidden = try #require(screen.cursor)
        screen.show(CursorUpdate(x: 9, y: 9, hotX: 0, hotY: 0, image: .unchanged))
        let moved = try #require(screen.cursor)
        #expect(shown < replaced && replaced < hidden.pictureGeneration)
        #expect(hidden.picture == nil && moved.picture == nil && moved.pictureGeneration == hidden.pictureGeneration)
    }
}
