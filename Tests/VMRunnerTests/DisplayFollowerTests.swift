import CoreGraphics
import Foundation
import TestKit
import Testing

@testable import VMRunner

/// A graphics display that records what it is asked for. It can refuse, and it can ignore a request the way a guest does that
/// has no driver yet.
@MainActor
private final class FakeDisplay: ResizableDisplay {
    struct Refused: Error {}

    var sizeInPixels: CGSize
    var requests: [CGSize] = []
    var refusals = 0
    var followsRequests = true

    init(sizeInPixels: CGSize = CGSize(width: 1280, height: 782)) { self.sizeInPixels = sizeInPixels }

    func reconfigure(sizeInPixels size: CGSize) throws {
        requests.append(size)
        if refusals > 0 {
            refusals -= 1
            throw Refused()
        }
        if followsRequests { sizeInPixels = size }
    }
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct DisplayFollowerTests {
    private let quiet = DisplayFollower.quietPeriod
    private let clock = TestClock()
    private let events = AsyncEventProbe<DisplayFollower.Event>()
    private let display = FakeDisplay()

    private func makeFollower(scale: Double = 1, enabled: Bool = true, hold: Duration = .zero) -> DisplayFollower {
        DisplayFollower(
            scale: scale, enabled: enabled, hold: hold, clock: clock, display: { [display] in display },
            report: { [events] in events.record($0) })
    }

    private func size(_ width: CGFloat, _ height: CGFloat) -> CGSize { CGSize(width: width, height: height) }

    private struct Refusal: Equatable {
        var attempt: Int
        var retryIn: Duration?
    }

    private func refusals() -> [Refusal] {
        events.events.compactMap {
            if case .refused(_, _, let attempt, let retryIn) = $0 { Refusal(attempt: attempt, retryIn: retryIn) } else { nil }
        }
    }

    /// Lets the quiet period pass for the request that was just scheduled.
    private func letQuietPass() async throws {
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: quiet)
    }

    // MARK: Which size is asked for

    @Test func theTargetIsTheViewInPointsTimesTheScaleRoundedDownToEven() {
        #expect(DisplayFollower.pixels(for: size(1001, 653), scale: 1) == size(1000, 652))
        #expect(DisplayFollower.pixels(for: size(1001, 653), scale: 2) == size(2002, 1306))
        #expect(DisplayFollower.pixels(for: size(1800, 1100), scale: 1) == size(1800, 1100))
    }

    @Test func aViewUnder64PointsOrNotANumberIsNotFollowed() {
        let unusable = [size(63, 800), size(800, 63), size(0, 0), size(.nan, 500), size(500, .infinity), size(-300, 500)]
        for view in unusable { #expect(DisplayFollower.pixels(for: view, scale: 1) == nil, "\(view)") }
    }

    @Test func aHugeViewIsScaledDownToTheLargestFramebufferKeepingItsShape() throws {
        let target = try #require(DisplayFollower.pixels(for: size(20000, 10000), scale: 2))
        #expect(target.width <= CGFloat(EditorLimits.displayWidth.upperBound))
        #expect(target.height <= CGFloat(EditorLimits.displayHeight.upperBound))
        #expect(abs(target.width / target.height - 2) < 0.01)
        #expect(Int(target.width).isMultiple(of: 2) && Int(target.height).isMultiple(of: 2))
    }

    // MARK: When it is asked for

    @Test func aBurstOfSizesIsOneRequestForTheLastSize() async throws {
        let follower = makeFollower()
        for width in stride(from: 1800, through: 1000, by: -100) { follower.viewResized(to: size(CGFloat(width), CGFloat(width * 3 / 5))) }
        try await letQuietPass()
        _ = try await events.wait(forAtLeast: 1)

        #expect(display.requests == [size(1000, 600)])
    }

    @Test func nothingIsRequestedForAViewUnder64Points() async throws {
        let follower = makeFollower()
        follower.viewResized(to: size(40, 900))
        follower.viewResized(to: size(900, 40))
        #expect(clock.sleeperCount == 0, "nothing was scheduled")
        #expect(events.events == [.ignored(points: size(40, 900)), .ignored(points: size(900, 40))])
        #expect(display.requests.isEmpty)
    }

    @Test func aTinyViewAfterAGoodOneKeepsTheGoodRequestPending() async throws {
        let follower = makeFollower()
        follower.viewResized(to: size(1200, 800))
        follower.viewResized(to: size(30, 30))
        try await letQuietPass()
        _ = try await events.wait(forAtLeast: 2)

        #expect(display.requests == [size(1200, 800)])
    }

    @Test func layingOutAgainAtTheSameSizeDoesNotPostponeTheRequest() async throws {
        let follower = makeFollower()
        follower.viewResized(to: size(1200, 800))
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: quiet - .milliseconds(1))
        for _ in 0..<5 { follower.viewResized(to: size(1200, 800)) }
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: .milliseconds(1))
        _ = try await events.wait(forAtLeast: 1)

        #expect(display.requests == [size(1200, 800)])
    }

    @Test func aSizeThatRoundsToTheDisplaysSizeAsksForNothing() async throws {
        let follower = makeFollower()
        follower.viewResized(to: size(1200, 800))
        try await letQuietPass()
        _ = try await events.wait(forAtLeast: 1)

        follower.viewResized(to: size(1200.5, 800.5))
        try await letQuietPass()
        let seen = try await events.wait(forAtLeast: 2)

        #expect(display.requests == [size(1200, 800)])
        #expect(seen.last == .skipped(target: size(1200, 800)))
    }

    @Test func aDisplayThatMovedByItselfIsAskedAgain() async throws {
        let follower = makeFollower()
        follower.viewResized(to: size(1200, 800))
        try await letQuietPass()
        _ = try await events.wait(forAtLeast: 1)

        display.sizeInPixels = size(1024, 768)
        follower.viewResized(to: size(1200.5, 800.5))
        try await letQuietPass()
        _ = try await events.wait(forAtLeast: 2)

        #expect(display.requests == [size(1200, 800), size(1200, 800)])
    }

    @Test func aGuestThatIgnoresARequestIsNotAskedForTheSameSizeAgain() async throws {
        display.followsRequests = false
        let follower = makeFollower()
        follower.viewResized(to: size(1200, 800))
        try await letQuietPass()
        _ = try await events.wait(forAtLeast: 1)

        follower.viewResized(to: size(1200.5, 800.5))
        try await letQuietPass()
        _ = try await events.wait(forAtLeast: 2)

        #expect(display.requests == [size(1200, 800)], "the guest re-modesets on every request, so repeating one only flickers")
    }

    @Test func aFollowerThatIsOffAsksForNothingUntilItIsTurnedOn() async throws {
        let follower = makeFollower(enabled: false)
        follower.viewResized(to: size(1200, 800))
        #expect(clock.sleeperCount == 0)

        follower.configure(scale: 1, enabled: true)
        try await letQuietPass()
        _ = try await events.wait(forAtLeast: 1)
        #expect(display.requests == [size(1200, 800)])
    }

    @Test func aNewScaleAsksAgainForTheCurrentView() async throws {
        let follower = makeFollower()
        follower.viewResized(to: size(1200, 800))
        try await letQuietPass()
        _ = try await events.wait(forAtLeast: 1)

        follower.configure(scale: 2, enabled: true)
        try await letQuietPass()
        _ = try await events.wait(forAtLeast: 2)
        #expect(display.requests == [size(1200, 800), size(2400, 1600)])
    }

    // MARK: The firmware hold

    @Test func nothingIsRequestedWhileTheFirmwareHolds() async throws {
        let hold = DisplayFollower.firmwareHold
        let follower = makeFollower(hold: hold)
        try await clock.waitForSleepers(atLeast: 1)
        follower.viewResized(to: size(1800, 1100))
        follower.viewResized(to: size(1810, 1100))
        #expect(clock.sleeperCount == 1, "only the hold is pending: the size is remembered, not scheduled")

        clock.advance(by: hold - .milliseconds(1))
        #expect(display.requests.isEmpty && events.events.isEmpty)
        clock.advance(by: .milliseconds(1))
        _ = try await events.wait(forAtLeast: 1)
        #expect(events.events == [.released])

        try await letQuietPass()
        _ = try await events.wait(forAtLeast: 2)
        #expect(display.requests == [size(1810, 1100)], "the last size, once the hold is over and the view has been quiet")
    }

    @Test func aViewMadeAfterTheHoldIsNotHeld() async throws {
        let follower = makeFollower(hold: .zero)
        follower.viewResized(to: size(1800, 1100))
        try await letQuietPass()
        _ = try await events.wait(forAtLeast: 1)
        #expect(display.requests == [size(1800, 1100)])
    }

    // MARK: A refused request

    @Test func aRefusedRequestIsReportedAndRetriedWithGrowingDelays() async throws {
        display.refusals = 2
        let follower = makeFollower()
        follower.viewResized(to: size(1200, 800))
        try await letQuietPass()
        _ = try await events.wait(forAtLeast: 2)
        #expect(refusals() == [Refusal(attempt: 1, retryIn: .milliseconds(500))])

        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: .milliseconds(499))
        #expect(display.requests.count == 1)
        clock.advance(by: .milliseconds(1))
        _ = try await events.wait(forAtLeast: 4)
        #expect(refusals().last == Refusal(attempt: 2, retryIn: .seconds(1)))

        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: .seconds(1))
        _ = try await events.wait(forAtLeast: 5)
        #expect(display.requests.count == 3)
        #expect(display.sizeInPixels == size(1200, 800), "the third try got through")
    }

    @Test func aDisplayThatKeepsRefusingIsGivenUpOnUntilTheViewChanges() async throws {
        display.refusals = 100
        let follower = makeFollower()
        follower.viewResized(to: size(1200, 800))
        try await letQuietPass()
        var seen = 0
        for attempt in 1...DisplayFollower.maximumRetries {
            seen += 2
            _ = try await events.wait(forAtLeast: seen)
            try await clock.waitForSleepers(atLeast: 1)
            clock.advance(by: DisplayFollower.firstRetryDelay * (1 << (attempt - 1)))
        }
        seen += 2
        _ = try await events.wait(forAtLeast: seen)

        #expect(refusals().last == Refusal(attempt: DisplayFollower.maximumRetries + 1, retryIn: nil))
        #expect(display.requests.count == DisplayFollower.maximumRetries + 1)
        #expect(clock.sleeperCount == 0, "no retry is left pending")

        display.refusals = 0
        follower.viewResized(to: size(1300, 800))
        try await letQuietPass()
        _ = try await events.wait(forAtLeast: seen + 1)
        #expect(display.requests.last == size(1300, 800), "a new size starts over")
        #expect(display.sizeInPixels == size(1300, 800))
    }

    @Test func aNewSizeCancelsAPendingRetryOfTheOldOne() async throws {
        display.refusals = 1
        let follower = makeFollower()
        follower.viewResized(to: size(1200, 800))
        try await letQuietPass()
        _ = try await events.wait(forAtLeast: 2)
        try await clock.waitForSleepers(atLeast: 1)

        follower.viewResized(to: size(1400, 900))
        try await letQuietPass()
        _ = try await events.wait(forAtLeast: 3)
        clock.advance(by: .seconds(60))

        #expect(display.requests == [size(1200, 800), size(1400, 900)], "the stale retry did not run")
    }

    @Test func aMissingDisplayIsReportedNotATrap() async throws {
        let follower = DisplayFollower(
            scale: 1, enabled: true, hold: .zero, clock: clock, display: { nil }, report: { [events] in events.record($0) })
        follower.viewResized(to: size(1200, 800))
        try await letQuietPass()
        #expect(try await events.wait(forAtLeast: 1) == [.noDisplay])
    }

    // MARK: A realistic sequence

    @Test func startDragMaximiseAndFullScreenEndOnTheLastWindowSize() async throws {
        let hold = DisplayFollower.firmwareHold
        let follower = makeFollower(hold: hold)
        try await clock.waitForSleepers(atLeast: 1)
        follower.viewResized(to: size(1290, 806))  // the first layout, while the firmware runs
        clock.advance(by: hold)
        _ = try await events.wait(forAtLeast: 1)  // released
        try await letQuietPass()
        _ = try await events.wait(forAtLeast: 2)
        #expect(display.requests == [size(1290, 806)])

        for width in stride(from: 1290, through: 1700, by: 20) {  // a drag to the right edge
            follower.viewResized(to: size(CGFloat(width), CGFloat(width) * 0.62))
        }
        follower.viewResized(to: size(1800, 1100))  // maximise
        try await letQuietPass()
        _ = try await events.wait(forAtLeast: 3)
        #expect(display.requests.last == size(1800, 1100))

        follower.viewResized(to: size(2880, 1800))  // full screen in
        try await letQuietPass()
        _ = try await events.wait(forAtLeast: 4)
        #expect(display.requests.last == size(2880, 1800))

        follower.viewResized(to: size(1800, 1100))  // and out again
        try await letQuietPass()
        _ = try await events.wait(forAtLeast: 5)
        #expect(display.requests == [size(1290, 806), size(1800, 1100), size(2880, 1800), size(1800, 1100)])
    }
}

struct DisplayDiagnosticsTests {
    @Test func tracingIsOffUnlessTheLaunchArgumentIsPresent() {
        #expect(!DisplayDiagnostics.isRequested(in: ["/Applications/VMRunner.app/Contents/MacOS/VMRunner"]))
        #expect(!DisplayDiagnostics.isRequested(in: ["VMRunner", "--start", "Alpine"]))
        #expect(DisplayDiagnostics.isRequested(in: ["VMRunner", "--display-diagnostics"]))
        #expect(DisplayDiagnostics.isRequested(in: ["VMRunner", "--start", "Alpine", "--display-diagnostics"]))
    }

    @Test func theLaunchArgumentIsDocumentedInTheHelp() {
        let help = HelpTopic.launchArguments.entry
        #expect((help.paragraphs + help.advanced).joined(separator: " ").contains(DisplayDiagnostics.argument))
    }

    @Test func aSizeIsLoggedAsWholeNumbers() {
        #expect(DisplayDiagnostics.text(CGSize(width: 1800.4, height: 1100)) == "1800×1100")
    }

    @Test func everyEventNamesTheSizesInvolved() {
        let target = CGSize(width: 1200, height: 800)
        let events: [DisplayFollower.Event] = [
            .ignored(points: CGSize(width: 30, height: 30)),
            .skipped(target: target),
            .requested(points: CGSize(width: 1200.5, height: 800.5), target: target, displayWas: CGSize(width: 1280, height: 782)),
            .refused(target: target, errorKind: "VZErrorDomain 1", attempt: 2, retryIn: .seconds(1)),
            .refused(target: target, errorKind: "VZErrorDomain 1", attempt: 6, retryIn: nil),
        ]
        let text = events.map(\.description)
        #expect(text[0].contains("30×30"))
        #expect(text[1].contains("1200×800"))
        #expect(text[2].contains("1200×800") && text[2].contains("1280×782"))
        #expect(text[3].contains("VZErrorDomain 1") && text[3].contains("attempt 2") && text[3].contains("retrying"))
        #expect(text[4].contains("giving up"))
    }
}
