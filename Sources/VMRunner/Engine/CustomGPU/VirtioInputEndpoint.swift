import VirtioGPU
import VirtioInput

/// A queue element of the event queue as one of the library's buffers: the room the guest left for an event, a write, and the
/// one way back.
struct EventSlot<Element: QueueElement>: GuestEventBuffer {
    let element: Element

    var writeCapacity: Int { element.writableByteCount }

    func put(_ bytes: [UInt8]) throws {
        try element.write(bytes)
    }

    func giveBack() {
        element.giveBack()
    }
}

/// A queue element of the status queue as one of the library's buffers.
struct StatusSlot<Element: QueueElement>: GuestStatusBuffer {
    let element: Element

    var byteCount: Int { element.readableByteCount }

    func take(count: Int) throws -> [UInt8] {
        try element.read(count: count)
    }

    func giveBack() {
        element.giveBack()
    }
}

/// What a virtio input device does with its two queues, over any queue of elements, so that it is tested without a machine.
///
/// **The event queue.** The guest posts empty buffers; the device keeps them (`takeBuffers`) and gives each one back exactly
/// once, with one event in it, when there is an event for it (`send`). The library holds at most 1024 and gives one over the
/// limit back at once. A buffer given back with no event would show the guest the event it held last, so none is given back
/// without one but the ones the library refuses.
///
/// **A reset or a stop** forgets every buffer held (`forgetHeld`) and every event not yet delivered, and gives none back: the
/// guest's queue is reset with the device, and the framework raises an exception when an element is returned to a queue that no
/// longer has it.
///
/// **The status queue.** Each element is read once, decoded and given back at once, whatever it holds.
@MainActor
final class VirtioInputEndpoint<Queue: ElementQueue> {
    private var events = InputEventQueue<EventSlot<Queue.Element>>()
    /// The status elements that were not one event of 8 bytes, since the endpoint was made.
    private(set) var malformedStatusCount = 0

    /// How many frames the event queue dropped since the last `forgetHeld`, because the guest holds no buffers for them.
    var droppedFrameCount: Int { events.droppedFrameCount }

    /// Takes up to `budget` buffers (at least one) the guest posted. Returns `true` when the budget ended the turn: more may
    /// wait, and the caller must come back for them, because the guest notifies once for a batch and not again.
    func takeBuffers(from queue: Queue, budget: Int) -> Bool {
        let budget = max(budget, 1)
        var taken = 0
        while taken < budget, let element = queue.nextElement() {
            events.hold(EventSlot(element: element))
            taken += 1
        }
        return taken == budget
    }

    /// Serves up to `budget` elements (at least one) of the status queue, with the same return value as `takeBuffers`.
    func serveStatus(from queue: Queue, budget: Int) -> Bool {
        let budget = max(budget, 1)
        var served = 0
        while served < budget, let element = queue.nextElement() {
            if case .malformed = InputStatus.serve(StatusSlot(element: element)) { malformedStatusCount += 1 }
            served += 1
        }
        return served == budget
    }

    /// Frames of events for the guest, each ending in a report, written to the buffers held as they allow.
    func send(_ frames: [InputEvent]) {
        events.enqueue(frames)
    }

    /// Lets go of the buffers held and the events waiting, without giving anything back.
    func forgetHeld() {
        events = InputEventQueue()
    }
}
