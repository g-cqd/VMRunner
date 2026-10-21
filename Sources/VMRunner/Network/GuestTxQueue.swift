/// Frames the guest socket would not take yet, kept in order until it drains.
///
/// Slots are allocated the first time the queue has to hold a frame and reused afterwards, so a socket that never
/// blocks costs nothing and one that blocks occasionally stops allocating after the first burst. The queue is
/// bounded; a full queue refuses frames, which for TCP means a retransmission and for UDP a lost datagram.
final class GuestTxQueue {
    private struct Slot {
        let buffer: RawBuffer
        var length: Int
    }

    private let slotCapacity: Int
    private let maximumSlots: Int
    private var free: [Slot] = []
    private var queued: [Slot] = []
    private var head = 0
    private var allocated = 0

    init(slotCapacity: Int, maximumSlots: Int) {
        self.slotCapacity = slotCapacity
        self.maximumSlots = maximumSlots
    }

    var isEmpty: Bool { head == queued.count }

    /// Copies `frame` into the queue. `false` when the queue is full or the frame does not fit a slot.
    func enqueue(_ frame: ByteView) -> Bool {
        guard frame.count <= slotCapacity else { return false }
        var slot: Slot
        if let reused = free.popLast() {
            slot = reused
        } else if allocated < maximumSlots {
            slot = Slot(buffer: RawBuffer(capacity: slotCapacity), length: 0)
            allocated += 1
        } else {
            return false
        }
        slot.buffer.mutableView.copy(frame, to: 0)
        slot.length = frame.count
        queued.append(slot)
        return true
    }

    /// The oldest frame, valid until ``dropFirst()``.
    func first() -> ByteView? {
        head < queued.count ? queued[head].buffer.view(length: queued[head].length) : nil
    }

    func dropFirst() {
        guard head < queued.count else { return }
        free.append(queued[head])
        head += 1
        if head == queued.count {
            queued.removeAll(keepingCapacity: true)
            head = 0
        }
    }

    func removeAll() {
        while !isEmpty { dropFirst() }
    }
}
