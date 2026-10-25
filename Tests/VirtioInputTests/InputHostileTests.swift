import Testing

@testable import VirtioInput

/// Random operations on the event queue and random status buffers: whatever the host and the guest do, nothing traps, the queue
/// stays within its bounds, every buffer is given back at most once and every event is accounted for.
struct InputHostileTests {
    /// Splits a stream of events into the frames that end in a report; the events after the last report are left over.
    private static func frames(of events: [InputEvent]) -> [[InputEvent]] {
        var frames: [[InputEvent]] = []
        var current: [InputEvent] = []
        for event in events {
            current.append(event)
            if event.endsFrame {
                frames.append(current)
                current = []
            }
        }
        return frames
    }

    @Test
    func aHundredThousandRandomOperationsKeepTheQueueWithinItsBoundsAndAccountForEveryEvent() {
        var generator = XorShiftGenerator(seed: 0x1_0004)
        var queue = InputEventQueue<FakeEventBuffer>(capacity: 24, maxHeldBuffers: 10)
        var buffers: [FakeEventBuffer] = []
        var sent: [[InputEvent]] = []
        var enqueuedEvents = 0
        for tag in 0..<100_000 {
            if Bool.random(using: &generator) {
                let events = frame(Int.random(in: 1...30, using: &generator), tag: Int32(tag))
                sent.append(events)
                enqueuedEvents += events.count
                queue.enqueue(events)
            } else {
                let buffer = FakeEventBuffer(
                    capacity: [0, 7, 8, 9, 4096].randomElement(using: &generator) ?? 8,
                    failsToWrite: Int.random(in: 0..<8, using: &generator) == 0)
                buffers.append(buffer)
                queue.hold(buffer)
            }
            #expect(queue.pendingEventCount <= 24 && queue.heldBufferCount <= 10)
        }
        let delivered = buffers.compactMap(\.event)
        #expect(enqueuedEvents == delivered.count + queue.droppedEventCount + queue.pendingEventCount)
        #expect(buffers.allSatisfy { $0.givenBackCount <= 1 })
        #expect(buffers.map(\.givenBackCount).reduce(0, +) == buffers.count - queue.heldBufferCount)
        #expect(buffers.filter { $0.written.isEmpty }.count - queue.heldBufferCount == queue.unusedBufferCount)
        // What the guest saw is whole frames of what was sent, in order: a dropped frame is gone entirely.
        let seen = Self.frames(of: delivered)
        var next = sent.startIndex
        for frame in seen {
            guard let index = sent[next...].firstIndex(of: frame) else {
                Issue.record("a frame the guest saw was not sent whole, or out of order")
                return
            }
            next = index + 1
        }
    }

    @Test
    func randomStatusBuffersNeverTrapAndAreGivenBackExactlyOnce() {
        var generator = XorShiftGenerator(seed: 0x1_0005)
        for _ in 0..<5000 {
            let length = [0, 1, 7, 8, 8, 8, 9, 4096, Int.max, Int.min].randomElement(using: &generator) ?? 8
            let content = (0..<8).map { _ in UInt8.random(in: 0...255, using: &generator) }
            let buffer = FakeStatusBuffer(byteCount: length, content: content, failsToRead: Int.random(in: 0..<10, using: &generator) == 0)
            let outcome = InputStatus.serve(buffer)
            #expect(buffer.givenBackCount == 1 && buffer.takes.count <= 1)
            if length != 8 {
                #expect(outcome == .malformed(length: length) && buffer.takes.isEmpty)
            } else if case .event(let event) = outcome {
                #expect(event.bytes == content)
            } else {
                #expect(outcome == .unreadable)
            }
        }
    }
}
