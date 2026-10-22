import CoreGraphics
import Foundation
import TestKit
import Testing

@testable import VMRunner

/// A guest that ignores a request may answer later, once its display driver has loaded, so the follower asks again with a
/// growing wait, and stops when it is answered or no longer wants that size.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct DisplayReaskTests {
    private let quiet = DisplayFollower.quietPeriod
    private let clock = TestClock()
    private let events = AsyncEventProbe<DisplayFollower.Event>()
    private let display = FakeDisplay()
    private let wanted = CGSize(width: 1200, height: 800)

    init() {
        display.followsRequests = false
        display.answers = false
    }

    private func makeFollower(hold: Duration = .zero) -> DisplayFollower {
        DisplayFollower(
            scale: 1, enabled: true, hold: hold, clock: clock, display: { [display] in display },
            report: { [events] in events.record($0) })
    }

    private func count(_ matches: (DisplayFollower.Event) -> Bool) -> Int { events.events.filter(matches).count }
    private var ignored: Int { count { if case .guestIgnored = $0 { true } else { false } } }
    private var repeats: [Int] { events.events.compactMap { if case .askedAgain(_, let attempt) = $0 { attempt } else { nil } } }

    private func waitFor(_ condition: () -> Bool) async throws {
        while !condition() { _ = try await events.wait(forAtLeast: events.count + 1) }
    }

    /// The first request, made and left unanswered for the response time.
    private func firstRequestIgnored(_ follower: DisplayFollower) async throws {
        follower.viewResized(to: wanted)
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: quiet)
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: DisplayFollower.responseTimeout)
        try await waitFor { ignored == 1 }
    }

    /// Lets the wait before repeat `attempt` pass and the repeat go unanswered too.
    private func repeatIgnored(_ attempt: Int) async throws {
        let before = ignored
        try await clock.waitForSleepers(atLeast: 1)
        let delay = DisplayFollower.reaskDelay(attempt: attempt)
        clock.advance(by: delay - .milliseconds(1))
        #expect(repeats.count == attempt - 1, "repeat \(attempt) waits the whole \(delay)")
        clock.advance(by: .milliseconds(1))
        try await waitFor { repeats.count == attempt }
        try await clock.waitForSleepers(atLeast: 1)  // its response clock
        clock.advance(by: DisplayFollower.responseTimeout)
        try await waitFor { ignored == before + 1 }
    }

    @Test func theWaitsGrowFromTwoSecondsToHalfAMinuteAndStayThere() {
        let seconds = (1...8).map { DisplayFollower.reaskDelay(attempt: $0) / .seconds(1) }
        #expect(seconds == [2, 4, 8, 16, 30, 30, 30, 30])
        #expect(DisplayFollower.reaskDelay(attempt: 0) == .seconds(2) && DisplayFollower.reaskDelay(attempt: -3) == .seconds(2))
    }

    @Test func anIgnoredRequestIsRepeatedWithGrowingWaitsAndOnePendingWaitAtATime() async throws {
        let follower = makeFollower()
        try await firstRequestIgnored(follower)
        for attempt in 1...7 {
            try await clock.waitForSleepers(atLeast: 1)
            for _ in 0..<5 { await Task.yield() }  // anything else that was going to park has parked
            #expect(clock.sleeperCount == 1, "one wait is pending, never two")
            try await repeatIgnored(attempt)
        }

        #expect(repeats == Array(1...7))
        #expect(display.requests == Array(repeating: wanted, count: 8))
        #expect(
            events.events.contains(.askedAgain(target: wanted, attempt: 7)),
            "each repeat is reported once, with its number and size")
        withExtendedLifetime(follower) {}
    }

    @Test func aResponseEndsTheRepeats() async throws {
        let follower = makeFollower()
        try await firstRequestIgnored(follower)
        try await repeatIgnored(1)
        try await clock.waitForSleepers(atLeast: 1)

        display.endReconfiguration()
        try await waitFor { count { if case .guestResponded = $0 { true } else { false } } == 1 }
        #expect(clock.sleeperCount == 0, "nothing is left pending")
        clock.advance(by: .seconds(600))
        #expect(display.requests.count == 2)
        withExtendedLifetime(follower) {}
    }

    @Test func aNewSizeOfTheViewStartsTheWaitsOver() async throws {
        let follower = makeFollower()
        try await firstRequestIgnored(follower)
        try await repeatIgnored(1)
        try await repeatIgnored(2)

        let other = CGSize(width: 1400, height: 900)
        follower.viewResized(to: other)
        try await clock.waitForSleepers(atLeast: 2)  // the wait before repeat 3, and the quiet period
        clock.advance(by: quiet)
        try await waitFor { display.requests.last == other }
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: DisplayFollower.responseTimeout)
        try await waitFor { ignored == 4 }

        let before = display.requests.count
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: DisplayFollower.reaskDelay(attempt: 1))
        try await waitFor { repeats.last == 1 && display.requests.count == before + 1 }
        #expect(display.requests.last == other, "the old size is not asked again, and the count starts at one")
        withExtendedLifetime(follower) {}
    }

    @Test func aViewThatLaysOutAtTheSameTargetDoesNotEndTheRepeats() async throws {
        let follower = makeFollower()
        try await firstRequestIgnored(follower)
        follower.viewResized(to: CGSize(width: 1200.5, height: 800.5))
        try await clock.waitForSleepers(atLeast: 2)
        clock.advance(by: quiet)
        try await waitFor { count { if case .skipped = $0 { true } else { false } } == 1 }

        clock.advance(by: DisplayFollower.reaskDelay(attempt: 1) - quiet)  // the wait began before the layout
        try await waitFor { repeats == [1] }
        #expect(display.requests == [wanted, wanted])
        withExtendedLifetime(follower) {}
    }

    @Test func nothingIsAskedForASizeTheDisplayAlreadyShows() async throws {
        let follower = makeFollower()
        try await firstRequestIgnored(follower)
        try await clock.waitForSleepers(atLeast: 1)

        display.sizeInPixels = wanted  // the guest got there by itself
        clock.advance(by: DisplayFollower.reaskDelay(attempt: 1))
        try await waitFor { events.events.last == .reachedWithoutRequest(target: wanted) }
        #expect(display.requests.count == 1 && repeats.isEmpty)
        #expect(clock.sleeperCount == 0)
        withExtendedLifetime(follower) {}
    }

    @Test func aViewResizedToTheSizeTheDisplayShowsEndsTheRepeats() async throws {
        let follower = makeFollower()
        try await firstRequestIgnored(follower)

        follower.viewResized(to: CGSize(width: 1280, height: 782))  // what the display shows
        try await clock.waitForSleepers(atLeast: 2)
        clock.advance(by: quiet)
        try await waitFor { events.events.last == .reachedWithoutRequest(target: CGSize(width: 1280, height: 782)) }
        #expect(clock.sleeperCount == 0)
        withExtendedLifetime(follower) {}
    }

    @Test func aFollowerThatIsLetGoStopsAskingAndLeavesNothingPending() async throws {
        var follower: DisplayFollower? = makeFollower()
        try await firstRequestIgnored(try #require(follower))
        try await clock.waitForSleepers(atLeast: 1)

        follower = nil
        #expect(clock.sleeperCount == 0, "the pending wait was cancelled with the follower")
        clock.advance(by: .seconds(600))
        #expect(display.requests.count == 1)
        #expect(follower == nil)
    }

    @Test func aFollowerThatIsTurnedOffStopsAsking() async throws {
        let follower = makeFollower()
        try await firstRequestIgnored(follower)
        try await clock.waitForSleepers(atLeast: 1)

        follower.configure(scale: 1, enabled: false)
        clock.advance(by: .seconds(600))
        #expect(display.requests.count == 1)
    }

    @Test func aViewThatBecameTooSmallStopsTheRepeats() async throws {
        let follower = makeFollower()
        try await firstRequestIgnored(follower)
        try await clock.waitForSleepers(atLeast: 1)

        follower.viewResized(to: CGSize(width: 30, height: 30))
        clock.advance(by: .seconds(600))
        #expect(display.requests.count == 1)
    }

    @Test func nothingIsAskedWhileTheFirmwareHolds() async throws {
        let follower = makeFollower(hold: DisplayFollower.firmwareHold)
        try await clock.waitForSleepers(atLeast: 1)
        follower.viewResized(to: wanted)
        clock.advance(by: DisplayFollower.firmwareHold - .milliseconds(1))
        #expect(display.requests.isEmpty && clock.sleeperCount == 1, "only the hold is pending")
    }
}
