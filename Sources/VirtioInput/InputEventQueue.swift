/// A buffer of the event queue as the device sees it: room the guest left for one event, and the one way back to the guest.
/// The driver posts 8-byte buffers and, when it gets one back, reads an event out of it whatever the used length says, so a
/// buffer returned unwritten shows the guest the event it held last. The queue returns a buffer unwritten only to refuse it.
package protocol GuestEventBuffer {  // @dw:accept:this referenced-only-by-tests -- the app links it later
    /// The bytes the guest left room for.
    var writeCapacity: Int { get }
    /// Writes the bytes into the buffer; called only when they fit `writeCapacity`.
    func put(_ bytes: [UInt8]) throws
    /// Gives the buffer back to the guest, which is told that it is used. Called exactly once per buffer, after any write.
    func giveBack()
}

/// The events waiting for the guest and the buffers the guest has posted, paired one to one: the adapter hands every buffer it
/// takes from the event queue to `hold` instead of giving it back, and the queue gives it back with one event in it.
///
/// Events wait in a bounded list. Only whole frames (events up to an `EV_SYN` / `SYN_REPORT`) are handed to the guest, and when
/// the list is full the frame being added is dropped whole, as the specification advises, so the guest never sees half of one.
/// A dropped frame can be a key's release; the guest then keeps the key down until it sees the key again.
package struct InputEventQueue<Buffer: GuestEventBuffer> {  // @dw:accept:this referenced-only-by-tests -- the app links it later
    private let capacity: Int
    private let maxHeldBuffers: Int
    /// Events not yet written to a buffer, oldest first; the first `completeCount` of them end in a report.
    private var pending: [InputEvent] = []
    private var completeCount = 0
    /// The frame being added was dropped and the rest of it, up to its report, is dropped too.
    private var skippingFrame = false
    private var held: [Buffer] = []

    package private(set) var droppedEventCount = 0
    package private(set) var droppedFrameCount = 0
    /// Buffers returned to the guest with no event: too small for one, one a write failed on, or one over the held limit.
    package private(set) var unusedBufferCount = 0

    /// A queue of at most `capacity` events (one at least) that holds at most `maxHeldBuffers` buffers. The driver posts 64.
    package init(capacity: Int = 256, maxHeldBuffers: Int = 1024) {
        self.capacity = max(capacity, 1)
        self.maxHeldBuffers = max(maxHeldBuffers, 1)
    }

    package var pendingEventCount: Int { pending.count }
    package var heldBufferCount: Int { held.count }

    /// Adds the events, oldest first, and writes whatever the held buffers take.
    package mutating func enqueue(_ events: [InputEvent]) {
        for event in events { add(event) }
        drain()
    }

    /// Takes a buffer the guest posted, and writes to it, and to the ones before it, whatever events wait.
    package mutating func hold(_ buffer: Buffer) {
        if held.count < maxHeldBuffers {
            held.append(buffer)
        } else {
            unusedBufferCount += 1
            buffer.giveBack()
        }
        drain()
    }

    private mutating func add(_ event: InputEvent) {
        if skippingFrame {
            droppedEventCount += 1
            skippingFrame = !event.endsFrame
        } else if pending.count == capacity {
            // Full: the frame being added goes whole, the events of it that wait and the rest of it.
            let partial = pending.count - completeCount
            pending.removeLast(partial)
            droppedEventCount += partial + 1
            droppedFrameCount += 1
            skippingFrame = !event.endsFrame
        } else {
            pending.append(event)
            if event.endsFrame { completeCount = pending.count }
        }
    }

    /// Pairs the oldest complete events with the oldest buffers. A buffer that cannot take an event goes back unwritten and the
    /// event waits for the next one; every buffer is looked at once, so this ends.
    private mutating func drain() {
        var buffersUsed = 0
        var eventsSent = 0
        while eventsSent < completeCount, buffersUsed < held.count {
            let buffer = held[buffersUsed]
            buffersUsed += 1
            if buffer.writeCapacity >= InputWire.eventSize, (try? buffer.put(pending[eventsSent].bytes)) != nil {
                eventsSent += 1
            } else {
                unusedBufferCount += 1
            }
            buffer.giveBack()
        }
        held.removeFirst(buffersUsed)
        pending.removeFirst(eventsSent)
        completeCount -= eventsSent
    }
}

/// A buffer of the status queue: what the driver wrote for the device, such as an `EV_LED` event for a keyboard's lights.
package protocol GuestStatusBuffer {
    /// The bytes the guest wrote.
    var byteCount: Int { get }
    /// Copies the first `count` bytes; called at most once.
    func take(count: Int) throws -> [UInt8]
    /// Gives the buffer back to the guest. Called exactly once.
    func giveBack()
}

/// What one status buffer held.
package enum StatusOutcome: Equatable, Sendable {
    /// A well-formed event. The host ignores it today; the lights of a keyboard would follow it.
    case event(InputEvent)
    /// Not one event: any length but 8. Nothing was read.
    case malformed(length: Int)
    /// The 8 bytes could not be read.
    case unreadable
}

/// Serving of the status queue: the driver's messages to the device are decoded and, for now, only counted by the adapter.
package enum InputStatus {  // @dw:accept:this referenced-only-by-tests -- the app links it later
    /// Decodes one status buffer and gives it back exactly once. It reads at most 8 bytes, whatever length the guest claims.
    package static func serve(_ buffer: some GuestStatusBuffer) -> StatusOutcome {
        defer { buffer.giveBack() }
        let length = buffer.byteCount
        guard length == InputWire.eventSize else { return .malformed(length: length) }
        guard let bytes = try? buffer.take(count: length) else { return .unreadable }
        guard let event = InputEvent(bytes: bytes) else { return .malformed(length: bytes.count) }
        return .event(event)
    }
}
