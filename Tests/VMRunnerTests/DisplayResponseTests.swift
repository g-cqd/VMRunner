import CoreGraphics
import Foundation
import TestKit
import Testing

@testable import VMRunner

/// Whether the guest answered a request for a new display size: the framework reports no error when it does not, so
/// `DisplayFollower` listens for the end of the reconfiguration and gives the guest `responseTimeout`.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct DisplayResponseTests {
    private let quiet = DisplayFollower.quietPeriod
    private let clock = TestClock()
    private let events = AsyncEventProbe<DisplayFollower.Event>()
    private let display = FakeDisplay()

    private func makeFollower() -> DisplayFollower {
        DisplayFollower(
            scale: 1, enabled: true, hold: .zero, clock: clock, display: { [display] in display },
            report: { [events] in events.record($0) })
    }

    private func size(_ width: CGFloat, _ height: CGFloat) -> CGSize { CGSize(width: width, height: height) }

    /// The answers and the silences, without the requests.
    private var outcomes: [DisplayFollower.Event] {
        events.events.filter {
            switch $0 {
            case .guestResponded, .guestIgnored: true
            default: false
            }
        }
    }

    private func waitForOutcomes(_ count: Int) async throws {
        while outcomes.count < count { _ = try await events.wait(forAtLeast: events.count + 1) }
    }

    private func waitForRequests(_ count: Int) async throws {
        while events.events.filter({ if case .requested = $0 { true } else { false } }).count < count {
            _ = try await events.wait(forAtLeast: events.count + 1)
        }
    }

    /// Lets the quiet period pass for the request that was just scheduled.
    private func letQuietPass() async throws {
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: quiet)
    }

    /// A display whose guest says nothing and shows nothing new.
    private func silentGuest() {
        display.followsRequests = false
        display.answers = false
    }

    @Test func aGuestThatAnswersIsReportedWithTheSizeTheFrameworkShows() async throws {
        let follower = makeFollower()
        follower.viewResized(to: size(1200, 800))
        try await letQuietPass()
        try await waitForOutcomes(1)

        #expect(outcomes == [.guestResponded(target: size(1200, 800), displayIs: size(1200, 800))])
        #expect(clock.sleeperCount == 0, "an answered request leaves no clock running")
    }

    @Test func aGuestThatSaysNothingIsReportedOnceTheResponseTimeIsOver() async throws {
        silentGuest()
        let follower = makeFollower()
        follower.viewResized(to: size(1200, 800))
        try await letQuietPass()
        try await waitForRequests(1)
        try await clock.waitForSleepers(atLeast: 1)

        clock.advance(by: DisplayFollower.responseTimeout - .milliseconds(1))
        #expect(outcomes.isEmpty, "two seconds have not passed yet")
        clock.advance(by: .milliseconds(1))
        try await waitForOutcomes(1)
        #expect(outcomes == [.guestIgnored(target: size(1200, 800), displayIs: size(1280, 782))])
    }

    @Test func anAnswerAfterTheReportIsReportedToo() async throws {
        silentGuest()
        let follower = makeFollower()
        follower.viewResized(to: size(1200, 800))
        try await letQuietPass()
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: DisplayFollower.responseTimeout)
        try await waitForOutcomes(1)

        display.endReconfiguration()
        try await waitForOutcomes(2)
        let kinds = outcomes.map { if case .guestResponded = $0 { "answered" } else { "ignored" } }
        #expect(kinds == ["ignored", "answered"], "the last report says what the guest did last")
    }

    @Test func aNewRequestStartsTheResponseTimeOverAndTheOldOneIsNotReported() async throws {
        silentGuest()
        let follower = makeFollower()
        follower.viewResized(to: size(1200, 800))
        try await letQuietPass()
        try await waitForRequests(1)
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: .seconds(1))

        follower.viewResized(to: size(1400, 900))
        try await clock.waitForSleepers(atLeast: 2)  // the first response clock and the quiet period
        clock.advance(by: quiet)
        try await waitForRequests(2)
        clock.advance(by: .seconds(1))
        #expect(outcomes.isEmpty, "the first request is superseded, and the second has not had its two seconds")

        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: .seconds(1))
        try await waitForOutcomes(1)
        #expect(outcomes == [.guestIgnored(target: size(1400, 900), displayIs: size(1280, 782))])
    }

    @Test func aReconfigurationThatNobodyRequestedReportsNothing() async throws {
        let follower = makeFollower()
        follower.viewResized(to: size(1200, 800))
        try await letQuietPass()
        try await waitForOutcomes(1)

        display.endReconfiguration()
        display.endReconfiguration()
        #expect(outcomes.count == 1, "the framework's own resize is not an answer to anything")
    }

    @Test func aRefusedRequestIsNotWaitedForAndTheDisplayIsObservedOnce() async throws {
        silentGuest()
        display.refusals = 1
        let follower = makeFollower()
        follower.viewResized(to: size(1200, 800))
        try await letQuietPass()
        try await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: DisplayFollower.firstRetryDelay)
        try await waitForRequests(2)

        #expect(display.observerCount == 1)
        #expect(outcomes.isEmpty)
    }
}
