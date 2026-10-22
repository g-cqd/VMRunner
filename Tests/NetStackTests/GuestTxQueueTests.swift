import Testing

@testable import NetStack

struct GuestTxQueueTests {
    /// How many 100-byte frames the queue takes, out of `attempts`, before it refuses them.
    private func accepted(by queue: GuestTxQueue, attempts: Int = 100) -> Int {
        let frame = [UInt8](repeating: 7, count: 100)
        return (0..<attempts).filter { _ in ByteView.withBytes(of: frame) { queue.enqueue($0) } }.count
    }

    @Test func theQueueHoldsNoMoreSlotsThanItsByteBudgetPaysFor() {
        #expect(accepted(by: GuestTxQueue(slotCapacity: 1_000, maximumSlots: 50, maximumBytes: 4_000)) == 4)
        #expect(accepted(by: GuestTxQueue(slotCapacity: 1_000, maximumSlots: 3, maximumBytes: 4_000)) == 3, "nor more than its frames")
        #expect(accepted(by: GuestTxQueue(slotCapacity: 1_000, maximumSlots: 50, maximumBytes: 10)) == 1, "one slot whatever the budget")
    }

    @Test func theLargestMTUKeepsTheQueueWithinItsBudget() {
        let slot = 65_535 + EthernetHeader.length + 64
        let queue = GuestTxQueue(slotCapacity: slot, maximumSlots: 2_048, maximumBytes: GuestTxQueue.byteBudget)
        #expect(accepted(by: queue, attempts: 300) == GuestTxQueue.byteBudget / slot)
        #expect(GuestTxQueue.byteBudget / (1_500 + EthernetHeader.length + 64) >= 2_048, "the default MTU keeps its 2,048 frames")
    }

    @Test func aDrainedQueueTakesFramesAgain() {
        let queue = GuestTxQueue(slotCapacity: 1_000, maximumSlots: 2, maximumBytes: 4_000)
        #expect(accepted(by: queue) == 2)
        queue.dropFirst()
        #expect(accepted(by: queue) == 1)
        queue.removeAll()
        #expect(queue.isEmpty && accepted(by: queue) == 2)
    }
}
