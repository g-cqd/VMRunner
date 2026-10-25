import Testing

@testable import VirtioGPU

/// The decoder against well-formed requests of every type and against requests a hostile guest could send.
struct GPUDecoderTests {
    private static let limits = GPULimits()

    private static func decode(_ bytes: [UInt8], limits: GPULimits = limits) -> Result<GPUCommand, GPUDecodeFailure> {
        GPUDecoder.decode(bytes, limits: limits).command
    }

    private static let rect = GPURect(x: 1, y: 2, width: 3, height: 4)

    static let wellFormed: [(bytes: [UInt8], command: GPUCommand)] = [
        (request(.getDisplayInfo), .getDisplayInfo),
        (
            request(.resourceCreate2D, words: [7, 1, 640, 480]),
            .resourceCreate2D(resourceID: 7, format: 1, width: 640, height: 480)
        ),
        (request(.resourceUnref, words: [7, 0]), .resourceUnref(resourceID: 7)),
        (request(.setScanout, words: [1, 2, 3, 4, 0, 7]), .setScanout(rect: rect, scanoutID: 0, resourceID: 7)),
        (request(.resourceFlush, words: [1, 2, 3, 4, 7, 0]), .resourceFlush(rect: rect, resourceID: 7)),
        (transfer(rect, offset: 0x1_0000_0002, resource: 7), .transferToHost2D(rect: rect, offset: 0x1_0000_0002, resourceID: 7)),
        (
            request(.resourceAttachBacking, words: [7, 2], tail: entryBytes([(0x4000_0000, 4096), (0x5000_0000, 100)])),
            .resourceAttachBacking(
                resourceID: 7,
                entries: [GPUMemoryEntry(address: 0x4000_0000, length: 4096), GPUMemoryEntry(address: 0x5000_0000, length: 100)])
        ),
        (request(.resourceDetachBacking, words: [7, 0]), .resourceDetachBacking(resourceID: 7)),
        (request(.getEDID, words: [0, 0]), .getEDID(scanoutID: 0)),
        (
            request(.updateCursor, words: [0, 10, 20, 0, 9, 3, 4, 0]),
            .updateCursor(GPUCursor(scanoutID: 0, x: 10, y: 20, resourceID: 9, hotX: 3, hotY: 4))
        ),
        (request(.moveCursor, words: [0, 10, 20, 0, 0, 0, 0, 0]), .moveCursor(GPUCursor(scanoutID: 0, x: 10, y: 20))),
    ]

    @Test(arguments: 0..<wellFormed.count)
    func everyTypeDecodesFromItsExactSize(row: Int) throws {
        let (bytes, command) = Self.wellFormed[row]
        #expect(Self.decode(bytes) == .success(command))
        #expect(Self.decode(bytes + [0xAA, 0xBB, 0xCC]) == .success(command), "trailing bytes are ignored")
    }

    /// Row 0, the display-information request, is a header alone: one byte short of it is the case below.
    @Test(arguments: 1..<wellFormed.count)
    func aRequestOneByteShortIsUnsupported(row: Int) throws {
        let bytes = Self.wellFormed[row].bytes
        let type = try #require(GPUCommandType(rawValue: word(bytes, at: 0)))
        let fixed = GPUDecoder.fixedSize(of: type)
        let result = Self.decode(Array(bytes.prefix(fixed - 1)))
        #expect(result == .failure(.shorterThanCommand(type: type.rawValue, needed: fixed, length: fixed - 1)))
        if case .failure(let failure) = result { #expect(failure.responseType == .errUnspec) }
    }

    @Test
    func theHeaderIsReadFieldByField() {
        let bytes = request(0x0100, flags: 3, fence: 0x0102_0304_0506_0708, context: 9, ring: 5)
        let decoded = GPUDecoder.decode(bytes, limits: Self.limits)
        #expect(decoded.header == GPUControlHeader(type: 0x0100, flags: 3, fenceID: 0x0102_0304_0506_0708, contextID: 9, ringIndex: 5))
    }

    @Test(arguments: [0, 1, 4, 23])
    func aRequestShorterThanAHeaderGetsAZeroedHeader(length: Int) {
        let decoded = GPUDecoder.decode(Array(request(.getDisplayInfo).prefix(length)), limits: Self.limits)
        #expect(decoded.header == .unreadable)
        #expect(decoded.command == .failure(.shorterThanHeader(length: length)))
    }

    @Test(arguments: [UInt32(0), 0x0108, 0x0109, 0x010b, 0x010c, 0x010d, 0x0200, 0x0207, 0x1100, 0xFFFF_FFFF])
    func otherTypesAreUnsupported(type: UInt32) {
        let result = Self.decode(request(type, words: Array(repeating: 0, count: 16)))
        #expect(result == .failure(.unsupported(type: type)))
    }

    @Test
    func aRequestLongerThanTheLimitIsRefusedBeforeDecoding() {
        let bytes = request(.getDisplayInfo, tail: Array(repeating: 0, count: Self.limits.maxCommandBytes))
        #expect(Self.decode(bytes) == .failure(.longerThanLimit(length: bytes.count)))
    }

    @Test(arguments: [UInt32(16_385), 0x0010_0000, UInt32.max])
    func anEntryCountOverTheLimitIsRefusedWithoutReadingEntries(count: UInt32) {
        let result = Self.decode(request(.resourceAttachBacking, words: [7, count]))
        #expect(result == .failure(.tooManyEntries(count: count)))
        if case .failure(let failure) = result { #expect(failure.responseType == .errInvalidParameter) }
    }

    @Test
    func anEntryCountLargerThanTheEntriesSentIsRefused() {
        let tail = entryBytes([(0x1000, 4096)]) + [1, 2, 3]
        #expect(Self.decode(request(.resourceAttachBacking, words: [7, 2], tail: tail)) == .failure(.entriesMissing(count: 2, length: 19)))
        #expect(Self.decode(request(.resourceAttachBacking, words: [7, 16_384])) == .failure(.entriesMissing(count: 16_384, length: 0)))
    }

    @Test
    func theEntryLimitIsInclusive() {
        var limits = GPULimits()
        limits.maxBackingEntries = 3
        let entries = entryBytes([(0x1000, 1), (0x2000, 2), (0x3000, 3)])
        #expect((try? Self.decode(request(.resourceAttachBacking, words: [7, 3], tail: entries), limits: limits).get()) != nil)
        #expect(
            Self.decode(request(.resourceAttachBacking, words: [7, 4], tail: entries), limits: limits)
                == .failure(.tooManyEntries(count: 4)))
        let four = request(.resourceAttachBacking, words: [7, 4], tail: entries + entryBytes([(0x4000, 4)]))
        #expect(Self.decode(four, limits: limits) == .failure(.longerThanLimit(length: 96)), "the length is checked first")
    }

    @Test
    func aZeroLengthOrWrappingEntryIsRefused() {
        let zero = entryBytes([(0x1000, 4096), (0x2000, 0)])
        #expect(Self.decode(request(.resourceAttachBacking, words: [7, 2], tail: zero)) == .failure(.invalidEntry(index: 1)))
        let wrapping = entryBytes([(UInt64.max - 10, 11)])
        #expect(Self.decode(request(.resourceAttachBacking, words: [7, 1], tail: wrapping)) == .failure(.invalidEntry(index: 0)))
        let lastByte = entryBytes([(UInt64.max - 10, 10)])
        #expect((try? Self.decode(request(.resourceAttachBacking, words: [7, 1], tail: lastByte)).get()) != nil)
    }

    @Test
    func anAnswerEchoesTheFenceOnlyWhenAsked() {
        let fenced = GPUControlHeader(type: 0x0105, flags: GPUControlHeader.fenceFlag | 0x80, fenceID: 42, contextID: 3, ringIndex: 7)
        let answer = GPUResponse.noData.encoded(answering: fenced)
        #expect(answer.count == GPUWireSize.header)
        #expect(word(answer, at: 0) == GPUResponseType.okNoData.rawValue)
        #expect(word(answer, at: 4) == GPUControlHeader.fenceFlag, "unknown flags are not echoed")
        #expect(word(answer, at: 8) == 42 && word(answer, at: 12) == 0)
        #expect(word(answer, at: 16) == 3)
        #expect(answer[20] == 0, "no ring index without its flag")

        let unfenced = GPUControlHeader(type: 0x0105, flags: 0, fenceID: 42, contextID: 3, ringIndex: 7)
        #expect(GPUResponse.error(.errInvalidParameter).encoded(answering: unfenced) == [0x05, 0x12] + Array(repeating: 0, count: 22))

        let ring = GPUControlHeader(type: 0x0105, flags: 3, fenceID: 1, contextID: 0, ringIndex: 7)
        #expect(GPUResponse.noData.encoded(answering: ring)[20] == 7)
    }

    @Test
    func aDisplayInfoAnswerCarriesSixteenModes() {
        let mode = GPUDisplayMode(rect: GPURect(x: 0, y: 0, width: 1280, height: 800), enabled: true)
        let answer = GPUResponse.displayInfo([mode]).encoded(answering: .unreadable)
        #expect(answer.count == GPUWireSize.displayInfo)
        #expect(word(answer, at: 0) == GPUResponseType.okDisplayInfo.rawValue)
        #expect([word(answer, at: 32), word(answer, at: 36), word(answer, at: 40)] == [1280, 800, 1])
        #expect(answer[48...].allSatisfy { $0 == 0 }, "the other fifteen modes are zero")
    }

    @Test
    func rectanglesFitAndIntersectWithoutOverflow() {
        #expect(GPURect(x: 0, y: 0, width: 10, height: 10).fits(width: 10, height: 10))
        #expect(!GPURect(x: 1, y: 0, width: 10, height: 10).fits(width: 10, height: 10))
        #expect(!GPURect(x: UInt32.max, y: 0, width: 2, height: 1).fits(width: UInt32.max, height: 1))
        #expect(!GPURect(x: 0, y: 0, width: UInt32.max, height: UInt32.max).fits(width: UInt32.max - 1, height: UInt32.max))
        let screen = GPURect(x: 0, y: 0, width: 100, height: 100)
        #expect(GPURect(x: 99, y: 99, width: 1, height: 1).intersects(screen))
        #expect(!GPURect(x: 100, y: 0, width: 5, height: 5).intersects(screen))
        #expect(!GPURect(x: 0, y: 0, width: 0, height: 0).intersects(screen))
        #expect(!GPURect(x: UInt32.max, y: UInt32.max, width: UInt32.max, height: UInt32.max).intersects(screen))
    }
}
