import CoreGraphics
import Foundation
import TestKit
import Testing

@testable import VMRunner
@testable import VirtioGPU

/// The custom GPU's display as the policy that resizes a Linux guest's display sees it: a request goes to the device, and the
/// guest has answered when it draws at the size that was asked for.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct CustomGPUResizeTests {
    private let source = FakeCustomSource()
    private let clock = TestClock()
    private let events = AsyncEventProbe<DisplayFollower.Event>()

    private func size(_ width: CGFloat, _ height: CGFloat) -> CGSize { CGSize(width: width, height: height) }

    private func picture(_ width: UInt32, _ height: UInt32) -> ScanoutUpdate {
        ScanoutUpdate(width: width, height: height, format: .b8g8r8x8, pixels: [])
    }

    // MARK: The display

    @Test
    func theDisplayIsAsBigAsTheMachineStartedUntilTheGuestDrawsAtAnotherSize() {
        let display = CustomGPUResizableDisplay(source: source)
        #expect(display.sizeInPixels == size(1280, 800))
        source.screen.show(picture(1024, 768))
        #expect(display.sizeInPixels == size(1024, 768))
    }

    @Test
    func aRequestGoesToTheDeviceInWholePixelsAndLeavesTheDisplayWhereItWas() throws {
        let display = CustomGPUResizableDisplay(source: source)
        try display.reconfigure(sizeInPixels: size(1920, 1080))
        #expect(source.requests == [size(1920, 1080)])
        #expect(display.sizeInPixels == size(1280, 800), "the guest has not drawn at the new size yet")
    }

    @Test
    func aRequestTheDeviceRefusesThrows() {
        source.accepts = false
        let display = CustomGPUResizableDisplay(source: source)
        #expect(throws: CustomGPUResizableDisplay.Refused.self) { try display.reconfigure(sizeInPixels: size(9000, 9000)) }
        #expect(source.requests == [size(9000, 9000)])
    }

    @Test(arguments: [-1, 0.5, 1280.25, .nan, .infinity, 5_000_000_000] as [CGFloat])
    func aSizeThatIsNotWholePixelsOfADisplayIsRefusedWithoutAskingTheDevice(width: CGFloat) {
        let display = CustomGPUResizableDisplay(source: source)
        #expect(throws: CustomGPUResizableDisplay.Refused.self) { try display.reconfigure(sizeInPixels: size(width, 800)) }
        #expect(throws: CustomGPUResizableDisplay.Refused.self) { try display.reconfigure(sizeInPixels: size(1280, width)) }
        #expect(source.requests.isEmpty)
    }

    // MARK: The end of a reconfiguration

    @Test
    func theEndIsReportedOnceWhenTheGuestFirstDrawsAtTheSizeThatWasAskedFor() throws {
        let display = CustomGPUResizableDisplay(source: source)
        var ends = 0
        let token = display.observeReconfigurationEnd { ends += 1 }

        source.screen.show(picture(1920, 1080))
        #expect(ends == 0, "no request has been made")
        try display.reconfigure(sizeInPixels: size(1920, 1080))
        source.screen.show(picture(1280, 800))
        #expect(ends == 0, "a picture of another size is not the answer")
        source.screen.show(picture(1920, 1080))
        source.screen.show(picture(1920, 1080))
        #expect(ends == 1, "the answer comes once per request")

        try display.reconfigure(sizeInPixels: size(800, 600))
        source.screen.show(picture(800, 600))
        #expect(ends == 2)
        withExtendedLifetime(token) {}
    }

    @Test
    func releasingTheRegistrationEndsTheReports() throws {
        let display = CustomGPUResizableDisplay(source: source)
        var ends = 0
        var token: AnyObject? = display.observeReconfigurationEnd { ends += 1 }
        try display.reconfigure(sizeInPixels: size(800, 600))
        token = nil
        source.screen.show(picture(800, 600))
        #expect(ends == 0 && token == nil)
    }

    // MARK: The policy driving it

    private func follower(for display: CustomGPUResizableDisplay) -> DisplayFollower {
        DisplayFollower(
            scale: 1, enabled: true, hold: .zero, clock: clock, display: { [display] in display },
            report: { [events] in events.record($0) })
    }

    private func letQuietPass() async throws {
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: DisplayFollower.quietPeriod)
    }

    private func waitForEvents(_ count: Int) async throws {
        while events.count < count { _ = try await events.wait(forAtLeast: events.count + 1) }
    }

    @Test
    func aWindowResizeAsksTheDeviceAndTheGuestsPictureAtTheSizeIsTheAnswer() async throws {
        let display = CustomGPUResizableDisplay(source: source)
        let follower = follower(for: display)
        follower.viewResized(to: size(1200, 800))
        try await letQuietPass()
        try await waitForEvents(1)
        #expect(source.requests == [size(1200, 800)])

        source.screen.show(picture(1200, 800))
        try await waitForEvents(2)
        #expect(events.events.last == .guestResponded(target: size(1200, 800), displayIs: size(1200, 800)))
        #expect(clock.sleeperCount == 0, "an answered request leaves no clock running")
    }

    @Test
    func aGuestThatDrawsNothingNewIsReportedAsIgnoringTheRequestAndAskedAgain() async throws {
        let display = CustomGPUResizableDisplay(source: source)
        let follower = follower(for: display)
        follower.viewResized(to: size(1200, 800))
        try await letQuietPass()
        try await waitForEvents(1)
        try await clock.waitForSleepers(atLeast: 1)

        clock.advance(by: DisplayFollower.responseTimeout)
        try await waitForEvents(2)
        #expect(events.events.last == .guestIgnored(target: size(1200, 800), displayIs: size(1280, 800)))

        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: DisplayFollower.reaskDelay(attempt: 1))
        try await waitForEvents(3)
        #expect(source.requests == [size(1200, 800), size(1200, 800)], "the second request is made like the first")
    }

    @Test
    func aDeviceThatRefusesTheSizeIsReportedAsARefusal() async throws {
        source.accepts = false
        let display = CustomGPUResizableDisplay(source: source)
        let follower = follower(for: display)
        follower.viewResized(to: size(1200, 800))
        try await letQuietPass()
        try await waitForEvents(2)
        guard case .refused(let target, _, let attempt, let retry) = events.events[1] else {
            Issue.record("expected a refusal, got \(events.events)")
            return
        }
        #expect(target == size(1200, 800) && attempt == 1 && retry != nil)
    }

    // MARK: The session

    @Test(.enabled(if: CustomGPUConfigurationTests.hostHasCustomDevices))
    func aSessionPassesTheRequestToItsDeviceAndTheDeviceRefusesWhatItCannotReport() {
        guard #available(macOS 27.0, *) else { return }
        let session = CustomGPUSession(display: (1280, 800))
        #expect(!session.requestDisplaySize(width: 0, height: 600))
        #expect(!session.requestDisplaySize(width: 7680, height: 4320))
        #expect(session.requestDisplaySize(width: 3840, height: 2160), "taken, though no machine has made the device yet")
        #expect(session.screen.pictureSize == size(1280, 800), "the guest has not drawn at it")
    }
}
