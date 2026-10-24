import Testing

@testable import VirtioGPURunnerCore

/// The device's handling of whole requests, in the order a guest's driver sends them to show a console.
struct GPUDeviceStateTests {
    /// A 4 × 2 surface's backing: 32 bytes at 0x4000 whose values are 0, 1, 2, ...
    private static func memory() -> FakeGuestMemory {
        var memory = FakeGuestMemory()
        memory.add(at: 0x4000, count: 32)
        return memory
    }

    private static func type(of answer: [UInt8]?) -> UInt32? {
        answer.map { word($0, at: 0) }
    }

    private static let okNoData = GPUResponseType.okNoData.rawValue

    /// Display information, then resource 1 (4 × 2, B8G8R8X8) created, backed, shown, filled and flushed.
    private static func showConsole(_ state: inout GPUDeviceState, memory: FakeGuestMemory) -> HandledCommand {
        _ = state.handle(request(.getDisplayInfo), queue: .control, memory: memory)
        _ = state.handle(request(.resourceCreate2D, words: [1, 2, 4, 2]), queue: .control, memory: memory)
        _ = state.handle(request(.resourceAttachBacking, words: [1, 1], tail: entryBytes([(0x4000, 32)])), queue: .control, memory: memory)
        _ = state.handle(request(.setScanout, words: [0, 0, 4, 2, 0, 1]), queue: .control, memory: memory)
        _ = state.handle(transfer(GPURect(x: 0, y: 0, width: 4, height: 2), offset: 0, resource: 1), queue: .control, memory: memory)
        return state.handle(request(.resourceFlush, words: [0, 0, 4, 2, 1, 0]), queue: .control, memory: memory)
    }

    @Test
    func theDisplayIsReportedAsOneEnabledMode() {
        var state = GPUDeviceState()
        let handled = state.handle(request(.getDisplayInfo), queue: .control, memory: Self.memory())
        let answer = handled.response ?? []
        #expect(answer.count == GPUWireSize.displayInfo)
        #expect([word(answer, at: 0), word(answer, at: 32), word(answer, at: 36), word(answer, at: 40)] == [0x1101, 1280, 800, 1])
        #expect(handled.logEntry.responseType == .okDisplayInfo && handled.logEntry.commandType == 0x0100)
    }

    @Test
    func aFlushOfTheScanoutGivesItsPicture() throws {
        var state = GPUDeviceState()
        let flushed = Self.showConsole(&state, memory: Self.memory())
        #expect(Self.type(of: flushed.response) == Self.okNoData)
        let update = try #require(flushed.scanoutUpdate)
        #expect(update.width == 4 && update.height == 2 && update.format == .b8g8r8x8)
        #expect(update.pixels == Array(0..<32))
        #expect(flushed.logEntry.sequence == 6 && flushed.logEntry.resourceID == 1)
    }

    @Test
    func aScanoutOfPartOfAResourceShowsOnlyThatPart() throws {
        var state = GPUDeviceState()
        _ = Self.showConsole(&state, memory: Self.memory())
        let set = state.handle(request(.setScanout, words: [1, 1, 2, 1, 0, 1]), queue: .control, memory: Self.memory())
        #expect(Self.type(of: set.response) == Self.okNoData)
        let flushed = state.handle(request(.resourceFlush, words: [0, 0, 4, 2, 1, 0]), queue: .control, memory: Self.memory())
        #expect(try #require(flushed.scanoutUpdate).pixels == Array(20..<28))
    }

    @Test
    func aFlushOutsideTheScanoutOrOfAnotherResourceGivesNoPicture() {
        var state = GPUDeviceState()
        _ = Self.showConsole(&state, memory: Self.memory())
        _ = state.handle(request(.setScanout, words: [0, 0, 2, 1, 0, 1]), queue: .control, memory: Self.memory())
        let outside = state.handle(request(.resourceFlush, words: [2, 1, 2, 1, 1, 0]), queue: .control, memory: Self.memory())
        #expect(Self.type(of: outside.response) == Self.okNoData && outside.scanoutUpdate == nil)
        _ = state.handle(request(.resourceCreate2D, words: [2, 2, 4, 2]), queue: .control, memory: Self.memory())
        let other = state.handle(request(.resourceFlush, words: [0, 0, 4, 2, 2, 0]), queue: .control, memory: Self.memory())
        #expect(Self.type(of: other.response) == Self.okNoData && other.scanoutUpdate == nil)
    }

    static let refused: [(bytes: [UInt8], answer: GPUResponseType)] = [
        (request(.setScanout, words: [0, 0, 4, 2, 1, 1]), .errInvalidScanoutID),
        (request(.setScanout, words: [0, 0, 4, 2, 0, 9]), .errInvalidResourceID),
        (request(.setScanout, words: [0, 0, 5, 2, 0, 1]), .errInvalidParameter),
        (request(.setScanout, words: [0, 0, 0, 0, 0, 1]), .errInvalidParameter),
        (request(.setScanout, words: [UInt32.max, 0, 2, 1, 0, 1]), .errInvalidParameter),
        (request(.resourceFlush, words: [0, 0, 4, 2, 9, 0]), .errInvalidResourceID),
        (request(.resourceFlush, words: [0, 0, 4, 3, 1, 0]), .errInvalidParameter),
        (request(.resourceCreate2D, words: [1, 2, 4, 2]), .errInvalidResourceID),
        (request(.resourceCreate2D, words: [3, 9, 4, 2]), .errInvalidParameter),
        (request(.resourceUnref, words: [9, 0]), .errInvalidResourceID),
        (request(.resourceAttachBacking, words: [1, 1], tail: entryBytes([(0x4000, 32)])), .errUnspec),
        (request(.resourceDetachBacking, words: [9, 0]), .errInvalidResourceID),
        (transfer(GPURect(x: 0, y: 0, width: 4, height: 2), offset: 1, resource: 1), .errInvalidParameter),
        (transfer(GPURect(x: 0, y: 0, width: 1, height: 1), offset: 0, resource: 0), .errInvalidResourceID),
        (request(.getEDID, words: [0, 0]), .errUnspec),
        (request(.moveCursor, words: [0, 1, 1, 0, 0, 0, 0, 0]), .errUnspec),
        (request(0x0108, words: [0, 0]), .errUnspec),
        (request(.resourceCreate2D, words: [3, 2]), .errUnspec),
        (Array(request(.getDisplayInfo).prefix(10)), .errUnspec),
        (request(.resourceAttachBacking, words: [3, UInt32.max]), .errInvalidParameter),
    ]

    @Test(arguments: 0..<refused.count)
    func aRefusedRequestIsAnsweredWithItsErrorAndChangesNothing(row: Int) throws {
        var state = GPUDeviceState()
        _ = Self.showConsole(&state, memory: Self.memory())
        let before = state.store.totalBytes
        let handled = state.handle(Self.refused[row].bytes, queue: .control, memory: Self.memory())
        let answer = try #require(handled.response)
        #expect(answer.count == GPUWireSize.header)
        #expect(word(answer, at: 0) == Self.refused[row].answer.rawValue)
        #expect(handled.logEntry.responseType == Self.refused[row].answer)
        #expect(state.store.totalBytes == before && state.scanout?.resourceID == 1)
    }

    @Test
    func unrefOfTheShownResourceTurnsTheScanoutOff() {
        var state = GPUDeviceState()
        _ = Self.showConsole(&state, memory: Self.memory())
        _ = state.handle(request(.resourceUnref, words: [1, 0]), queue: .control, memory: Self.memory())
        #expect(state.scanout == nil && state.store.isEmpty)
        var other = GPUDeviceState()
        _ = Self.showConsole(&other, memory: Self.memory())
        _ = other.handle(request(.setScanout, words: [0, 0, 0, 0, 0, 0]), queue: .control, memory: Self.memory())
        #expect(other.scanout == nil && other.store.count == 1)
    }

    @Test
    func aFencedRequestGetsItsFenceBack() {
        var state = GPUDeviceState()
        let bytes = request(GPUCommandType.resourceCreate2D.rawValue, flags: 1, fence: 77, context: 0, words: [1, 2, 4, 2])
        let answer = state.handle(bytes, queue: .control, memory: Self.memory()).response ?? []
        #expect(word(answer, at: 0) == Self.okNoData && word(answer, at: 4) == 1 && word(answer, at: 8) == 77)
    }

    @Test
    func cursorRequestsAreRecordedAndGetNoAnswer() {
        var state = GPUDeviceState()
        let update = state.handle(request(.updateCursor, words: [0, 5, 6, 0, 9, 1, 2, 0]), queue: .cursor, memory: Self.memory())
        #expect(update.response == nil && update.logEntry.responseType == nil && update.logEntry.queue == .cursor)
        _ = state.handle(request(.moveCursor, words: [0, 7, 8, 0, 0, 0, 0, 0]), queue: .cursor, memory: Self.memory())
        #expect(state.cursor == GPUCursor(scanoutID: 0, x: 7, y: 8, resourceID: 9, hotX: 1, hotY: 2))
        let control = state.handle(request(.getDisplayInfo), queue: .cursor, memory: Self.memory())
        let garbage = state.handle([1, 2, 3], queue: .cursor, memory: Self.memory())
        #expect(control.response == nil && garbage.response == nil)
    }

    @Test
    func resetForgetsResourcesScanoutAndCursorButNotTheSequence() {
        var state = GPUDeviceState()
        _ = Self.showConsole(&state, memory: Self.memory())
        _ = state.handle(request(.updateCursor, words: [0, 5, 6, 0, 9, 1, 2, 0]), queue: .cursor, memory: Self.memory())
        state.reset()
        #expect(state.store.isEmpty && state.store.totalBytes == 0 && state.scanout == nil && state.cursor == nil)
        #expect(state.handle(request(.getDisplayInfo), queue: .control, memory: Self.memory()).logEntry.sequence == 8)
    }
}
