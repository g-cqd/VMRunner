import Testing

@testable import VirtioGPU

/// What the host may change on the device (the display's size) and what it is told of the guest's cursor.
struct DisplayAndCursorTests {
    struct Size: Sendable {
        let width: UInt32
        let height: UInt32
    }

    /// The first mode of a display-information answer: the type, then the width, height and enabled flag of the mode.
    private static func mode(of state: inout GPUDeviceState) -> [UInt32] {
        let answer = state.handle(request(.getDisplayInfo), queue: .control, memory: FakeGuestMemory()).response ?? []
        return [word(answer, at: 0), word(answer, at: 32), word(answer, at: 36), word(answer, at: 40)]
    }

    static let accepted = [Size(width: 3840, height: 2160), Size(width: 5120, height: 2880), Size(width: 8192, height: 2048)]
    static let refused = [
        Size(width: 0, height: 600), Size(width: 800, height: 0), Size(width: 8193, height: 600), Size(width: 600, height: 8193),
        Size(width: 7680, height: 4320), Size(width: 8192, height: 8192), Size(width: UInt32.max, height: UInt32.max),
        Size(width: UInt32.max, height: 1),
    ]

    @Test
    func theHostCanResizeTheDisplayAndTheNextAnswerReportsTheNewSize() {
        var state = GPUDeviceState()
        let before = Self.mode(of: &state)
        let accepted = state.setDisplaySize(width: 1920, height: 1080)
        let after = Self.mode(of: &state)
        state.reset()
        let afterReset = Self.mode(of: &state)
        #expect(before == [0x1101, 1280, 800, 1])
        #expect(accepted)
        #expect(after == [0x1101, 1920, 1080, 1])
        #expect(afterReset == [0x1101, 1920, 1080, 1], "a guest reset does not undo the host's choice")
    }

    @Test(arguments: accepted)
    func aSizeThatFitsAResourceIsAccepted(size: Size) {
        var state = GPUDeviceState()
        let accepted = state.setDisplaySize(width: size.width, height: size.height)
        let create = request(.resourceCreate2D, words: [1, 2, size.width, size.height])
        let answer = state.handle(create, queue: .control, memory: FakeGuestMemory()).response ?? []
        #expect(accepted)
        #expect([state.displayWidth, state.displayHeight] == [size.width, size.height])
        #expect(word(answer, at: 0) == GPUResponseType.okNoData.rawValue, "the guest can allocate a scanout of the size it is told")
    }

    @Test(arguments: refused)
    func aSizeOutsideTheLimitsIsRefusedAndNothingChanges(size: Size) {
        var state = GPUDeviceState()
        let accepted = state.setDisplaySize(width: size.width, height: size.height)
        let mode = Self.mode(of: &state)
        #expect(!accepted)
        #expect(mode == [0x1101, 1280, 800, 1])
    }

    // MARK: Cursor

    /// A 64 × 64 resource 5 backed and filled from 16 KiB of guest memory whose bytes are 0, 1, 2, ... modulo 256.
    private static func stateWithCursorResource(side: UInt32 = 64) -> (state: GPUDeviceState, memory: FakeGuestMemory) {
        var state = GPUDeviceState()
        var memory = FakeGuestMemory()
        let bytes = Int(side) * Int(side) * 4
        memory.add(at: 0x4000, count: bytes)
        _ = state.handle(request(.resourceCreate2D, words: [5, 67, side, side]), queue: .control, memory: memory)
        _ = state.handle(
            request(.resourceAttachBacking, words: [5, 1], tail: entryBytes([(0x4000, UInt32(bytes))])), queue: .control, memory: memory)
        _ = state.handle(transfer(GPURect(x: 0, y: 0, width: side, height: side), offset: 0, resource: 5), queue: .control, memory: memory)
        return (state, memory)
    }

    private static func update(resource: UInt32, x: UInt32 = 10, y: UInt32 = 20) -> [UInt8] {
        request(.updateCursor, words: [0, x, y, 0, resource, 3, 4, 0])
    }

    @Test
    func anUpdateGivesThePositionTheHotSpotAndThePictureOfTheResource() throws {
        let (initial, memory) = Self.stateWithCursorResource()
        var state = initial
        let handled = state.handle(Self.update(resource: 5), queue: .cursor, memory: memory)
        let cursor = try #require(handled.cursorUpdate)
        #expect([cursor.x, cursor.y, cursor.hotX, cursor.hotY] == [10, 20, 3, 4])
        guard case .shown(let picture) = cursor.image else {
            Issue.record("no image: \(cursor.image)")
            return
        }
        #expect([picture.width, picture.height] == [64, 64] && picture.format == .r8g8b8a8)
        #expect(picture.pixels == (0..<64 * 64 * 4).map { UInt8(truncatingIfNeeded: $0) })
        #expect(handled.response == nil && handled.scanoutUpdate == nil)
    }

    @Test
    func aMoveKeepsTheImageAndTheHotSpotOfTheLastUpdate() throws {
        let (initial, memory) = Self.stateWithCursorResource()
        var state = initial
        let first = state.handle(request(.moveCursor, words: [0, 1, 2, 0, 0, 0, 0, 0]), queue: .cursor, memory: memory)
        #expect(first.cursorUpdate == CursorUpdate(x: 1, y: 2, hotX: 0, hotY: 0, image: .unchanged), "before any update")
        _ = state.handle(Self.update(resource: 5), queue: .cursor, memory: memory)
        let moved = state.handle(request(.moveCursor, words: [0, 30, 40, 0, 0, 0, 0, 0]), queue: .cursor, memory: memory)
        #expect(moved.cursorUpdate == CursorUpdate(x: 30, y: 40, hotX: 3, hotY: 4, image: .unchanged))
    }

    @Test(arguments: [0, 77] as [UInt32])
    func noResourceOrAnUnknownOneHidesTheCursor(resource: UInt32) throws {
        let (initial, memory) = Self.stateWithCursorResource()
        var state = initial
        let handled = state.handle(Self.update(resource: resource), queue: .cursor, memory: memory)
        #expect(try #require(handled.cursorUpdate).image == .hidden)
    }

    @Test
    func aCursorResourceLargerThanTheLimitIsHiddenAndOneAtTheLimitIsShown() throws {
        let (tooBig, bigMemory) = Self.stateWithCursorResource(side: 257)
        var oversized = tooBig
        let hidden = try #require(oversized.handle(Self.update(resource: 5), queue: .cursor, memory: bigMemory).cursorUpdate)
        #expect(hidden.image == .hidden)
        let (atTheLimit, memory) = Self.stateWithCursorResource(side: 256)
        var state = atTheLimit
        let shown = try #require(state.handle(Self.update(resource: 5), queue: .cursor, memory: memory).cursorUpdate)
        guard case .shown(let picture) = shown.image else {
            Issue.record("hidden at the limit")
            return
        }
        #expect(picture.pixels.count == 256 * 256 * 4)
    }

    @Test
    func onlyACursorRequestOnTheCursorQueueGivesACursorUpdate() {
        let (initial, memory) = Self.stateWithCursorResource()
        var state = initial
        let updates = [
            state.handle(Self.update(resource: 5), queue: .control, memory: memory),
            state.handle(request(.getDisplayInfo), queue: .cursor, memory: memory),
            state.handle([1, 2, 3], queue: .cursor, memory: memory),
            state.handle(request(.resourceFlush, words: [0, 0, 1, 1, 5, 0]), queue: .control, memory: memory),
        ]
        #expect(updates.allSatisfy { $0.cursorUpdate == nil })
    }
}
