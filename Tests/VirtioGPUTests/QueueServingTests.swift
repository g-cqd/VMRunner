import Testing

@testable import VirtioGPU

/// A queue element that records, in order, everything the device does to it.
private final class FakeQueueElement: QueueElement {
    struct Failure: Error {}

    private let payload: [UInt8]
    private let declaredLength: Int
    private let room: Int
    private let readFails: Bool
    private let writeFails: Bool
    private(set) var events: [String] = []
    private(set) var written: [UInt8] = []

    /// `declaredLength` is what the guest claims to have written; `payload` is what a read returns first, padded with zeros.
    init(payload: [UInt8] = [], declaredLength: Int? = nil, room: Int = 1 << 20, readFails: Bool = false, writeFails: Bool = false) {
        self.payload = payload
        self.declaredLength = declaredLength ?? payload.count
        self.room = room
        self.readFails = readFails
        self.writeFails = writeFails
    }

    var readableByteCount: Int { declaredLength }
    var writableByteCount: Int { room }
    var givenBack: Int { events.filter { $0 == "give back" }.count }
    var reads: [String] { events.filter { $0.hasPrefix("read") } }

    func read(count: Int) throws -> [UInt8] {
        events.append("read \(count)")
        if readFails { throw Failure() }
        return Array(payload.prefix(count)) + Array(repeating: 0, count: max(0, count - payload.count))
    }

    func write(_ bytes: [UInt8]) throws {
        events.append("write \(bytes.count)")
        if writeFails { throw Failure() }
        written = bytes
    }

    func giveBack() {
        events.append("give back")
    }
}

struct QueueServingTests {
    private func serve(_ element: FakeQueueElement, on queue: GPUQueueKind = .control, observed: ((HandledCommand) -> Void)? = nil)
        -> ServeOutcome
    {
        var state = GPUDeviceState()
        return state.serve(element, on: queue, memory: FakeGuestMemory()) { observed?($0) }
    }

    private let displayInfo = request(.getDisplayInfo)

    @Test
    func aRequestIsReadOnceHandledAnsweredAndGivenBackOnce() {
        let element = FakeQueueElement(payload: displayInfo)
        guard case .handled(.written) = serve(element) else {
            Issue.record("not answered")
            return
        }
        #expect(element.events == ["read 24", "write 408", "give back"])
        #expect(word(element.written, at: 0) == GPUResponseType.okDisplayInfo.rawValue)
    }

    @Test
    func anEmptyElementIsNotReadAndIsAnsweredAsUnsupported() {
        let element = FakeQueueElement()
        guard case .handled(.written) = serve(element) else {
            Issue.record("not answered")
            return
        }
        #expect(element.events == ["write 24", "give back"])
        #expect(word(element.written, at: 0) == GPUResponseType.errUnspec.rawValue)
    }

    @Test
    func aRequestLongerThanTheDeviceReadsIsRefusedAfterItsHeaderOnTheControlQueue() {
        let tooLong = GPULimits().maxCommandBytes + 1
        let fenced = request(GPUCommandType.getDisplayInfo.rawValue, flags: GPUControlHeader.fenceFlag, fence: 77)
        let element = FakeQueueElement(payload: fenced, declaredLength: tooLong)
        guard case .oversized(let length, .written) = serve(element) else {
            Issue.record("not refused")
            return
        }
        #expect(length == tooLong)
        #expect(element.events == ["read 24", "write 24", "give back"])
        #expect(word(element.written, at: 0) == GPUResponseType.errInvalidParameter.rawValue)
        #expect(word(element.written, at: 8) == 77, "the refusal echoes the fence")
    }

    @Test
    func aRequestLongerThanTheDeviceReadsIsGivenBackUnansweredOnTheCursorQueue() {
        let element = FakeQueueElement(declaredLength: 1 << 40)
        guard case .oversized(_, .notNeeded) = serve(element, on: .cursor) else {
            Issue.record("answered")
            return
        }
        #expect(element.events == ["read 24", "give back"])
    }

    @Test
    func anAnswerThatDoesNotFitTheGuestsRoomIsNotWritten() {
        let element = FakeQueueElement(payload: displayInfo, room: 407)
        guard case .handled(.didNotFit(let needed, let available)) = serve(element) else {
            Issue.record("written")
            return
        }
        #expect((needed, available) == (408, 407))
        #expect(element.events == ["read 24", "give back"])

        let refused = FakeQueueElement(declaredLength: GPULimits().maxCommandBytes + 1, room: 23)
        guard case .oversized(_, .didNotFit) = serve(refused) else {
            Issue.record("the refusal was written")
            return
        }
        #expect(refused.events == ["read 24", "give back"])
    }

    @Test
    func aRequestThatCannotBeReadIsGivenBackWithoutAnAnswer() {
        let element = FakeQueueElement(payload: displayInfo, readFails: true)
        guard case .unreadable(let length, _) = serve(element) else {
            Issue.record("read")
            return
        }
        #expect(length == 24)
        #expect(element.events == ["read 24", "give back"])
    }

    @Test
    func anAnswerThatCannotBeWrittenIsReportedAndTheElementIsStillGivenBack() {
        let element = FakeQueueElement(payload: displayInfo, writeFails: true)
        guard case .handled(.failed) = serve(element) else {
            Issue.record("written")
            return
        }
        #expect(element.events == ["read 24", "write 408", "give back"])
    }

    @Test
    func theCursorQueueGetsNoAnswerButItsElementsAreGivenBack() {
        let element = FakeQueueElement(payload: request(.moveCursor, words: Array(repeating: 0, count: 8)))
        guard case .handled(.notNeeded) = serve(element, on: .cursor) else {
            Issue.record("answered")
            return
        }
        #expect(element.events == ["read 56", "give back"])
    }

    @Test
    func theObserverSeesTheCommandOnceBeforeTheAnswerIsWritten() {
        let element = FakeQueueElement(payload: displayInfo)
        var seen: [String] = []
        _ = serve(element) { handled in
            seen = element.events
            #expect(handled.logEntry.commandType == GPUCommandType.getDisplayInfo.rawValue)
        }
        #expect(seen == ["read 24"], "the observer ran after the read and before the write")

        var calls = 0
        _ = serve(FakeQueueElement(declaredLength: GPULimits().maxCommandBytes + 1)) { _ in calls += 1 }
        _ = serve(FakeQueueElement(payload: displayInfo, readFails: true)) { _ in calls += 1 }
        #expect(calls == 0, "a refused or unreadable request is never handled")
    }

    @Test(
        arguments: [0, 1, 23, 24, 25, 56, 4096, 262_175, 262_176, 262_177, 1 << 20, 1 << 40],
        [GPUQueueKind.control, .cursor])
    func everyLengthIsReadAtMostOnceAndGivenBackExactlyOnceAsTheLastStep(length: Int, queue: GPUQueueKind) {
        let element = FakeQueueElement(payload: displayInfo, declaredLength: length)
        _ = serve(element, on: queue)
        #expect(element.reads.count <= 1)
        #expect(element.givenBack == 1)
        #expect(element.events.last == "give back")
    }

    @Test(arguments: [GPUQueueKind.control, .cursor])
    func everyFailureStillGivesTheElementBackExactlyOnce(queue: GPUQueueKind) {
        for (readFails, writeFails) in [(true, false), (false, true), (true, true)] {
            let element = FakeQueueElement(payload: displayInfo, readFails: readFails, writeFails: writeFails)
            _ = serve(element, on: queue)
            #expect(element.givenBack == 1 && element.events.last == "give back")
            #expect(element.reads.count == 1)
        }
    }
}
