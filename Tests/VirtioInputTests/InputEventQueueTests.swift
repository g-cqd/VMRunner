import Testing

@testable import VirtioInput

/// The pairing of waiting events with the buffers the guest posted, and the status queue's decoder.
struct InputEventQueueTests {
    private let press = InputEvents.key(30, .press)

    @Test
    func eventsWaitUntilBuffersArriveAndEachBufferTakesExactlyOne() {
        var queue = InputEventQueue<FakeEventBuffer>()
        queue.enqueue(press)
        #expect(queue.pendingEventCount == 2 && queue.heldBufferCount == 0)
        let first = FakeEventBuffer()
        let second = FakeEventBuffer()
        let third = FakeEventBuffer()
        queue.hold(first)
        #expect(first.event == press[0] && first.givenBackCount == 1 && queue.pendingEventCount == 1)
        queue.hold(second)
        queue.hold(third)
        #expect(second.event == .report && second.givenBackCount == 1)
        #expect(third.written.isEmpty && third.givenBackCount == 0, "no event for it yet: the buffer is held, not returned")
        #expect(queue.pendingEventCount == 0 && queue.heldBufferCount == 1 && queue.unusedBufferCount == 0)
    }

    @Test
    func eventsAreWrittenInTheOrderTheyWereQueued() {
        var queue = InputEventQueue<FakeEventBuffer>()
        let buffers = (0..<6).map { _ in FakeEventBuffer() }
        for buffer in buffers { queue.hold(buffer) }
        let frames = [InputEvents.key(30, .press), InputEvents.key(30, .release), InputEvents.scroll(notches: 2)]
        for events in frames { queue.enqueue(events) }
        #expect(buffers.compactMap(\.event) == frames.flatMap { $0 })
    }

    @Test
    func onlyWholeFramesAreHandedToTheGuest() {
        var queue = InputEventQueue<FakeEventBuffer>()
        let buffer = FakeEventBuffer()
        queue.hold(buffer)
        queue.enqueue([press[0]])
        #expect(buffer.written.isEmpty && queue.pendingEventCount == 1, "the report has not come: nothing is written")
        queue.enqueue([.report])
        #expect(buffer.event == press[0] && queue.pendingEventCount == 1)
    }

    @Test
    func aBufferTooSmallForAnEventGoesBackWithNothingWrittenAndTheEventWaits() {
        var queue = InputEventQueue<FakeEventBuffer>()
        let small = FakeEventBuffer(capacity: 7)
        let empty = FakeEventBuffer(capacity: 0)
        let fine = FakeEventBuffer(capacity: 4096)
        queue.enqueue(press)
        queue.hold(small)
        queue.hold(empty)
        #expect(small.written.isEmpty && small.givenBackCount == 1 && empty.written.isEmpty && empty.givenBackCount == 1)
        #expect(queue.pendingEventCount == 2 && queue.unusedBufferCount == 2)
        queue.hold(fine)
        #expect(fine.written == [press[0].bytes], "exactly eight bytes, however much room")
    }

    @Test
    func aBufferTheWriteFailsOnGoesBackAndTheEventGoesToTheNextOne() {
        var queue = InputEventQueue<FakeEventBuffer>()
        let broken = FakeEventBuffer(failsToWrite: true)
        let fine = FakeEventBuffer()
        queue.enqueue(press)
        queue.hold(broken)
        queue.hold(fine)
        #expect(broken.written.isEmpty && broken.givenBackCount == 1 && queue.unusedBufferCount == 1)
        #expect(fine.event == press[0] && queue.pendingEventCount == 1)
    }

    @Test
    func aFullQueueDropsTheWholeFrameThatDoesNotFit() {
        var queue = InputEventQueue<FakeEventBuffer>(capacity: 4)
        queue.enqueue(frame(2, tag: 1))
        queue.enqueue(frame(2, tag: 2))
        queue.enqueue(frame(2, tag: 3))
        #expect(queue.pendingEventCount == 4 && queue.droppedFrameCount == 1 && queue.droppedEventCount == 2)
        queue.enqueue(frame(3, tag: 4))
        #expect(queue.pendingEventCount == 4 && queue.droppedFrameCount == 2 && queue.droppedEventCount == 5)
        let buffers = (0..<6).map { _ in FakeEventBuffer() }
        for buffer in buffers { queue.hold(buffer) }
        #expect(buffers.compactMap(\.event) == frame(2, tag: 1) + frame(2, tag: 2))
    }

    @Test
    func aFrameThatFillsTheQueueHalfwayIsDroppedWithItsFirstEvents() {
        var queue = InputEventQueue<FakeEventBuffer>(capacity: 4)
        queue.enqueue(frame(2, tag: 1))
        queue.enqueue(frame(4, tag: 2))
        #expect(queue.pendingEventCount == 2, "the two events that fit were taken out again with the rest of the frame")
        #expect(queue.droppedFrameCount == 1 && queue.droppedEventCount == 4)
        queue.enqueue(frame(2, tag: 3))
        #expect(queue.pendingEventCount == 4)
    }

    @Test
    func aFrameLongerThanTheQueueIsDroppedWholeAcrossCallsAndTheNextFrameIsKept() {
        var queue = InputEventQueue<FakeEventBuffer>(capacity: 3)
        var events = frame(8, tag: 1)
        let last = events.removeLast()
        queue.enqueue(events)
        queue.enqueue([last])
        #expect(queue.pendingEventCount == 0 && queue.droppedFrameCount == 1 && queue.droppedEventCount == 8)
        queue.enqueue(frame(2, tag: 2))
        #expect(queue.pendingEventCount == 2 && queue.droppedFrameCount == 1)
    }

    @Test
    func theHeldBuffersAreBoundedAndTheOnesOverTheLimitGoBackAtOnce() {
        var queue = InputEventQueue<FakeEventBuffer>(maxHeldBuffers: 2)
        let buffers = (0..<4).map { _ in FakeEventBuffer() }
        for buffer in buffers { queue.hold(buffer) }
        #expect(queue.heldBufferCount == 2 && queue.unusedBufferCount == 2)
        #expect(buffers.map(\.givenBackCount) == [0, 0, 1, 1] && buffers.allSatisfy { $0.written.isEmpty })
    }

    @Test
    func aQueueOfNoCapacityStillHoldsOneEvent() {
        var queue = InputEventQueue<FakeEventBuffer>(capacity: 0, maxHeldBuffers: 0)
        queue.enqueue([.report, .report])
        #expect(queue.pendingEventCount == 1 && queue.droppedEventCount == 1)
        let buffer = FakeEventBuffer()
        queue.hold(buffer)
        #expect(buffer.event == .report && queue.heldBufferCount == 0 && queue.pendingEventCount == 0)
    }

    // MARK: Status queue

    private static let ledOn = InputEvent(type: 0x11, code: 1, value: 1)

    @Test
    func aStatusBufferOfAnEventIsDecodedAndGivenBackOnce() {
        let buffer = FakeStatusBuffer(byteCount: 8, content: Self.ledOn.bytes)
        #expect(InputStatus.serve(buffer) == .event(Self.ledOn))
        #expect(buffer.takes == [8] && buffer.givenBackCount == 1)
    }

    @Test(arguments: [0, 1, 7, 9, 16, 4096, 1 << 40, -1])
    func aStatusBufferOfAnyOtherLengthIsNotReadAndIsGivenBackOnce(length: Int) {
        let buffer = FakeStatusBuffer(byteCount: length, content: Self.ledOn.bytes)
        #expect(InputStatus.serve(buffer) == .malformed(length: length))
        #expect(buffer.takes.isEmpty && buffer.givenBackCount == 1)
    }

    @Test
    func aStatusBufferThatCannotBeReadIsGivenBackOnce() {
        let buffer = FakeStatusBuffer(byteCount: 8, failsToRead: true)
        #expect(InputStatus.serve(buffer) == .unreadable)
        #expect(buffer.takes == [8] && buffer.givenBackCount == 1)
    }
}
