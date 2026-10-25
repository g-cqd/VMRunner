import Testing

@testable import VirtioGPU

/// A queue of elements that counts what is taken from it and what is given back.
private final class FakeQueue: ElementQueue {
    final class Element: QueueElement {
        private(set) var givenBack = 0

        var readableByteCount: Int { 24 }
        var writableByteCount: Int { 1 << 20 }

        func read(count: Int) throws -> [UInt8] { request(.getDisplayInfo) }
        func write(_ bytes: [UInt8]) throws {}
        func giveBack() { givenBack += 1 }
    }

    let elements: [Element]
    private(set) var taken = 0

    init(count: Int) {
        elements = (0..<count).map { _ in Element() }
    }

    func nextElement() -> Element? {
        guard taken < elements.count else { return nil }
        defer { taken += 1 }
        return elements[taken]
    }

    var givenBackOnce: Bool {
        elements.prefix(taken).allSatisfy { $0.givenBack == 1 } && elements.dropFirst(taken).allSatisfy { $0.givenBack == 0 }
    }
}

/// A turn takes at most its budget of elements and says whether it must be continued, so a guest that keeps the ring full
/// cannot keep the caller's thread, and one that notifies once for a batch is still served all of it.
struct QueueTurnTests {
    private struct Turn {
        var more = false
        var served = 0
        var handled = 0
    }

    private func turn(_ state: inout GPUDeviceState, _ queue: FakeQueue, budget: Int) -> Turn {
        var result = Turn()
        result.more = state.serveTurn(
            from: queue, on: .control, memory: FakeGuestMemory(), budget: budget, whenHandled: { _ in result.handled += 1 },
            whenServed: { _ in result.served += 1 })
        return result
    }

    @Test
    func aBatchLargerThanTheBudgetIsServedInTurnsAndEveryElementIsGivenBackOnce() {
        var state = GPUDeviceState()
        let queue = FakeQueue(count: 7)
        var turns: [Turn] = []
        var taken: [Int] = []
        for _ in 0..<3 {
            turns.append(turn(&state, queue, budget: 3))
            taken.append(queue.taken)
        }
        #expect(turns.map(\.more) == [true, true, false])
        #expect(taken == [3, 6, 7])
        #expect(turns.map(\.served) == [3, 3, 1] && turns.map(\.handled) == [3, 3, 1])
        #expect(queue.givenBackOnce)
    }

    @Test
    func aQueueThatRunsDryBeforeTheBudgetEndsTheTurnWithNothingLeft() {
        var state = GPUDeviceState()
        let queue = FakeQueue(count: 2)
        let result = turn(&state, queue, budget: 5)
        #expect(!result.more && result.served == 2 && queue.taken == 2 && queue.givenBackOnce)
    }

    @Test
    func aBatchOfExactlyTheBudgetAsksForOneMoreTurnWhichFindsNothing() {
        var state = GPUDeviceState()
        let queue = FakeQueue(count: 4)
        #expect(turn(&state, queue, budget: 4).more, "the queue cannot be looked at without taking an element")
        let next = turn(&state, queue, budget: 4)
        #expect(!next.more && next.served == 0 && queue.taken == 4)
    }

    @Test(arguments: [0, -3])
    func aBudgetBelowOneStillServesOneElement(budget: Int) {
        var state = GPUDeviceState()
        let queue = FakeQueue(count: 3)
        let result = turn(&state, queue, budget: budget)
        #expect(result.more && result.served == 1 && queue.taken == 1)
    }

    @Test
    func anEmptyQueueTakesNothing() {
        var state = GPUDeviceState()
        let queue = FakeQueue(count: 0)
        let result = turn(&state, queue, budget: 8)
        #expect(!result.more && result.served == 0 && queue.taken == 0)
    }
}
