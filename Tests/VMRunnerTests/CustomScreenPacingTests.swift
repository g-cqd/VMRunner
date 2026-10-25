import CoreGraphics
import TestKit
import Testing

@testable import VMRunner
@testable import VirtioGPU

/// Counts what a screen hands to the view that draws it.
@MainActor
final class CountingPresenter: ScreenPresenter {
    private(set) var frames: [ScanoutUpdate] = []
    private(set) var cursors: [CursorState?] = []

    func present(frame: ScanoutUpdate) { frames.append(frame) }
    func present(cursor: CursorState?) { cursors.append(cursor) }

    /// The first byte of each picture shown, which is how the tests tell the pictures apart.
    var shown: [UInt8] { frames.map { $0.pixels[0] } }
}

/// A guest may flush hundreds of times a second; the screen gives the view at most one picture per interval, the newest, and
/// keeps no timer while it has nothing to hand over.
@MainActor
struct CustomScreenPacingTests {
    private let clock = TestClock()

    private func screen() -> CustomScreen {
        CustomScreen(displaySize: CGSize(width: 1280, height: 800), clock: clock)
    }

    private func picture(_ mark: UInt8) -> ScanoutUpdate {
        ScanoutUpdate(width: 1, height: 1, format: .b8g8r8x8, pixels: [mark, 0, 0, 0])
    }

    private func move(to x: UInt32) -> CursorUpdate {
        CursorUpdate(x: x, y: 0, hotX: 0, hotY: 0, image: .unchanged)
    }

    /// Lets the tasks the test started run until `condition` holds; a few hundred turns are far more than any of them needs.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    @Test
    func theFirstPictureIsShownAtOnceAndABurstAfterItIsOnePictureTheNewest() async throws {
        let screen = screen()
        let presenter = CountingPresenter()
        screen.attach(presenter)

        screen.show(picture(1))
        #expect(presenter.shown == [1])
        for mark: UInt8 in 2...9 { screen.show(picture(mark)) }
        #expect(presenter.shown == [1], "the rest of the burst waits for the interval")

        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: CustomScreen.frameInterval)
        await settle { presenter.shown.count == 2 }
        #expect(presenter.shown == [1, 9], "nine flushes made two pictures, and the second is the newest")
        #expect(clock.sleeperCount == 0, "nothing is pending once the newest picture was shown")
    }

    @Test
    func aPictureAfterAQuietIntervalIsShownAtOnce() async throws {
        let screen = screen()
        let presenter = CountingPresenter()
        screen.attach(presenter)
        screen.show(picture(1))
        clock.advance(by: CustomScreen.frameInterval)
        screen.show(picture(2))
        #expect(presenter.shown == [1, 2])
        #expect(clock.sleeperCount == 0, "a screen with nothing kept back waits for nothing")
    }

    @Test
    func aBurstWaitsOnOneTimerOnly() async throws {
        let screen = screen()
        let presenter = CountingPresenter()
        screen.attach(presenter)
        for mark: UInt8 in 1...50 { screen.show(picture(mark)) }
        try await clock.waitForSleepers(atLeast: 1)
        #expect(clock.sleeperCount == 1)
        #expect(presenter.shown == [1])
    }

    @Test
    func aScreenWithNoViewKeepsTheNewestPictureAndSchedulesNothing() async throws {
        let screen = screen()
        for mark: UInt8 in 1...5 { screen.show(picture(mark)) }
        #expect(clock.sleeperCount == 0)
        #expect(screen.frame == picture(5))

        let presenter = CountingPresenter()
        screen.attach(presenter)
        #expect(presenter.shown == [5], "a view that comes later draws the newest picture without waiting")
    }

    @Test
    func aViewThatReplacesAnotherIsTheOnlyOneDrawnTo() async throws {
        let screen = screen()
        let first = CountingPresenter()
        let second = CountingPresenter()
        screen.attach(first)
        screen.show(picture(1))
        screen.attach(second)
        #expect(second.shown == [1], "full screen's new view starts from the newest picture")
        clock.advance(by: CustomScreen.frameInterval)
        screen.show(picture(2))
        screen.detach(first)
        clock.advance(by: CustomScreen.frameInterval)
        screen.show(picture(3))
        #expect(first.shown == [1], "the old view is not drawn to once it was replaced")
        #expect(second.shown == [1, 2, 3], "and its late detach does not end the new view's drawing")
    }

    @Test
    func aDetachedViewIsNotDrawnTo() {
        let screen = screen()
        let presenter = CountingPresenter()
        screen.attach(presenter)
        screen.detach(presenter)
        screen.show(picture(1))
        #expect(presenter.frames.isEmpty && clock.sleeperCount == 0)
    }

    @Test
    func theCursorIsNotHeldBackAndAViewThatComesLaterIsGivenIt() {
        let screen = screen()
        let presenter = CountingPresenter()
        screen.attach(presenter)
        for x: UInt32 in 1...10 { screen.show(move(to: x)) }
        #expect(presenter.cursors.count == 11, "the attach and then each of the ten moves")
        #expect(presenter.cursors.last??.x == 10)

        let later = CountingPresenter()
        screen.attach(later)
        #expect(later.cursors.count == 1 && later.cursors.last??.x == 10)
    }

    @Test
    func aScreenLetGoWhileAPictureWaitsEndsItsTimer() async throws {
        var screen: CustomScreen? = self.screen()
        let presenter = CountingPresenter()
        screen?.attach(presenter)
        screen?.show(picture(1))
        screen?.show(picture(2))
        try await clock.waitForSleepers(atLeast: 1)

        screen = nil
        await settle { clock.sleeperCount == 0 }
        #expect(clock.sleeperCount == 0)
        #expect(presenter.shown == [1])
    }
}
