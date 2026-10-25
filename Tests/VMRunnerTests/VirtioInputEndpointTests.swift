import Testing

@testable import VMRunner
@testable import VirtioInput

/// The two queues of a virtio input device over fake elements: every buffer the guest posts is given back once, with an event,
/// and none after a reset.
@MainActor
struct VirtioInputEndpointTests {
    private let endpoint = VirtioInputEndpoint<FakeInputQueue>()

    /// What was done to an element when it was forgotten, to see that nothing is done to it afterwards.
    private struct Snapshot {
        let element: FakeQueueElement
        let written: Int
        let givenBack: Int

        init(element: FakeQueueElement) {
            self.element = element
            written = element.written.count
            givenBack = element.givenBackCount
        }

        var isUnchanged: Bool { element.written.count == written && element.givenBackCount == givenBack }
    }

    private func buffers(_ count: Int, room: Int = 8) -> [FakeQueueElement] {
        (0..<count).map { _ in FakeQueueElement(room: room) }
    }

    private func take(_ elements: [FakeQueueElement]) {
        _ = endpoint.takeBuffers(from: FakeInputQueue(elements), budget: 4096)
    }

    private func event(_ element: FakeQueueElement) -> InputEvent? {
        element.written.first.flatMap { InputEvent(bytes: $0) }
    }

    // MARK: The event queue

    @Test
    func theBuffersTheGuestPostedAreHeldAndNotGivenBackWithoutAnEvent() {
        let posted = buffers(3)
        take(posted)
        #expect(posted.allSatisfy { $0.givenBackCount == 0 && $0.written.isEmpty })
    }

    @Test
    func eachEventGoesToTheOldestBufferAndEachBufferIsGivenBackOnce() throws {
        let posted = buffers(5)
        take(posted)
        endpoint.send(InputEvents.key(30, .press))
        endpoint.send(InputEvents.key(30, .release))
        #expect(try posted.prefix(4).map { try #require(event($0)) } == InputEvents.key(30, .press) + InputEvents.key(30, .release))
        #expect(posted.map(\.givenBackCount) == [1, 1, 1, 1, 0], "the fifth waits for an event")
        endpoint.send(InputEvents.scroll(notches: 1))
        #expect(posted.map(\.givenBackCount) == [1, 1, 1, 1, 1] && posted.allSatisfy { $0.written.count <= 1 })
    }

    @Test
    func eventsWaitForTheBuffersTheGuestPostsLater() {
        endpoint.send(InputEvents.key(1, .press))
        let posted = buffers(3)
        take(posted)
        #expect(posted.map(\.givenBackCount) == [1, 1, 0] && event(posted[0]) == InputEvents.key(1, .press).first)
    }

    @Test
    func aBufferTooSmallForAnEventIsGivenBackWithNothingAndTheEventWaitsForTheNext() {
        let tiny = FakeQueueElement(room: 4)
        let failing = FakeQueueElement(failsToWrite: true)
        let good = FakeQueueElement()
        take([tiny, failing, good])
        endpoint.send(InputEvents.key(2, .press))
        #expect([tiny, failing].allSatisfy { $0.givenBackCount == 1 && $0.written.isEmpty })
        #expect(event(good) == InputEvents.key(2, .press).first && good.givenBackCount == 1)
    }

    @Test
    func aTurnTakesAtMostItsBudgetAndSaysWhenMoreMayWait() {
        let queue = FakeInputQueue(buffers(100))
        let turns = (0..<4).map { _ in endpoint.takeBuffers(from: queue, budget: 32) }
        #expect(turns == [true, true, true, false], "96 buffers in three turns; the fourth finds 4 and the queue dry")
        #expect(endpoint.takeBuffers(from: FakeInputQueue([]), budget: 0) == false, "a budget of 0 is read as 1, and the queue is dry")
    }

    @Test
    func aBufferOverTheLimitOfHeldOnesIsGivenBackAtOnceUnwritten() {
        let posted = buffers(1030)
        take(posted)
        #expect(posted.prefix(1024).allSatisfy { $0.givenBackCount == 0 })
        #expect(posted.suffix(6).allSatisfy { $0.givenBackCount == 1 && $0.written.isEmpty })
    }

    @Test
    func aResetForgetsTheBuffersHeldAndGivesNothingBack() {
        let before = buffers(4)
        take(before)
        endpoint.send(InputEvents.key(30, .press))
        #expect(before.map(\.givenBackCount) == [1, 1, 0, 0])

        endpoint.forgetHeld()
        endpoint.send(InputEvents.key(30, .release))
        let after = buffers(3)
        take(after)
        #expect(before.map(\.givenBackCount) == [1, 1, 0, 0] && before.map(\.written.count) == [1, 1, 0, 0], "never touched again")
        #expect(after.map(\.givenBackCount) == [1, 1, 0], "the events sent after the reset go to the buffers posted after it")
    }

    @Test
    func aResetForgetsTheEventsWaiting() {
        endpoint.send(InputEvents.key(30, .press))
        endpoint.forgetHeld()
        let posted = buffers(2)
        take(posted)
        #expect(posted.allSatisfy { $0.givenBackCount == 0 && $0.written.isEmpty }, "the press waited for a buffer and is stale now")
    }

    @Test
    func aFullQueueDropsWholeFramesAndCountsThem() {
        for _ in 0..<300 { endpoint.send(InputEvents.key(30, .press)) }
        #expect(endpoint.droppedFrameCount > 0)
        let posted = buffers(600)
        take(posted)
        #expect(posted.filter { $0.givenBackCount == 1 }.count == 256, "256 events were kept, in whole frames")
        endpoint.forgetHeld()
        #expect(endpoint.droppedFrameCount == 0)
    }

    // MARK: The status queue

    @Test
    func anEventOfEightBytesIsReadOnceAndGivenBack() {
        let led = FakeQueueElement(wrote: 8, content: [0x11, 0, 0, 0, 1, 0, 0, 0])
        _ = endpoint.serveStatus(from: FakeInputQueue([led]), budget: 8)
        #expect(led.reads == [8] && led.givenBackCount == 1 && endpoint.malformedStatusCount == 0)
    }

    @Test(arguments: [0, 1, 7, 9, 4096, Int.max])
    func aMessageOfAnyOtherLengthIsNotReadAndIsGivenBackOnce(length: Int) {
        let message = FakeQueueElement(wrote: length)
        _ = endpoint.serveStatus(from: FakeInputQueue([message]), budget: 8)
        #expect(message.reads.isEmpty && message.givenBackCount == 1 && endpoint.malformedStatusCount == 1)
    }

    @Test
    func aMessageThatCannotBeReadIsGivenBackOnceAndTheTurnIsBounded() {
        let broken = FakeQueueElement(wrote: 8, failsToRead: true)
        let rest = (0..<40).map { _ in FakeQueueElement(wrote: 8) }
        let queue = FakeInputQueue([broken] + rest)
        #expect(endpoint.serveStatus(from: queue, budget: 32), "the budget ended the turn")
        #expect(broken.givenBackCount == 1 && rest.prefix(31).allSatisfy { $0.givenBackCount == 1 })
        #expect(rest.suffix(9).allSatisfy { $0.givenBackCount == 0 }, "the rest wait for the next turn")
    }

    // MARK: Hostile sequences

    @Test
    func longRandomSequencesGiveEveryBufferBackAtMostOnceAndNoneAfterAReset() throws {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(state >> 33) % bound
        }
        var live: [FakeQueueElement] = []
        var forgotten: [Snapshot] = []
        var everything: [FakeQueueElement] = []
        for _ in 0..<4000 {
            switch next(10) {
            case 0..<4:
                let posted = buffers(1 + next(6))
                (live, everything) = (live + posted, everything + posted)
                take(posted)
            case 4..<9:
                endpoint.send(InputEvents.key(UInt16(1 + next(200)), next(2) == 0 ? .press : .release))
            default:
                forgotten += live.filter { $0.givenBackCount == 0 }.map { Snapshot(element: $0) }
                live = []
                endpoint.forgetHeld()
            }
        }
        #expect(everything.allSatisfy { $0.givenBackCount <= 1 && $0.written.count <= 1 && ($0.written.isEmpty || $0.givenBackCount == 1) })
        #expect(forgotten.allSatisfy { $0.isUnchanged })
    }
}
