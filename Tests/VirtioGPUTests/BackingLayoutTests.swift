import Testing

@testable import VirtioGPU

/// How a byte range of a resource's backing maps onto the guest memory entries behind it.
struct BackingLayoutTests {
    private static let layout = BackingLayout(entries: [
        GPUMemoryEntry(address: 0x1000, length: 100), GPUMemoryEntry(address: 0x9000, length: 50),
        GPUMemoryEntry(address: 0x5000, length: 10),
    ])

    struct Row {
        let range: (offset: UInt64, length: UInt64)
        let pieces: [GuestRange]?

        init(_ offset: UInt64, _ length: UInt64, _ pieces: [GuestRange]?) {
            range = (offset, length)
            self.pieces = pieces
        }
    }

    static let rows: [Row] = [
        Row(0, 100, [GuestRange(address: 0x1000, count: 100)]),
        Row(10, 20, [GuestRange(address: 0x100A, count: 20)]),
        Row(90, 20, [GuestRange(address: 0x105A, count: 10), GuestRange(address: 0x9000, count: 10)]),
        Row(
            50, 110,
            [GuestRange(address: 0x1032, count: 50), GuestRange(address: 0x9000, count: 50), GuestRange(address: 0x5000, count: 10)]
        ),
        Row(100, 50, [GuestRange(address: 0x9000, count: 50)]),
        Row(159, 1, [GuestRange(address: 0x5009, count: 1)]),
        Row(160, 0, []),
        Row(0, 0, []),
        Row(160, 1, nil),
        Row(159, 2, nil),
        Row(161, 0, nil),
        Row(UInt64.max, 1, nil),
        Row(1, UInt64.max, nil),
        Row(UInt64.max, UInt64.max, nil),
    ]

    @Test(arguments: 0..<rows.count)
    func aRangeMapsToThePiecesThatHoldIt(row: Int) throws {
        let layout = try #require(Self.layout)
        let expected = Self.rows[row]
        #expect(layout.totalLength == 160)
        #expect(layout.pieces(offset: expected.range.offset, length: expected.range.length) == expected.pieces)
    }

    @Test
    func entriesThatAreEmptyOrWrapAreRefused() {
        #expect(BackingLayout(entries: [GPUMemoryEntry(address: 0x1000, length: 0)]) == nil)
        #expect(BackingLayout(entries: [GPUMemoryEntry(address: UInt64.max, length: 1)]) == nil)
        #expect(BackingLayout(entries: [GPUMemoryEntry(address: UInt64.max - 1, length: 1)])?.totalLength == 1)
        #expect(BackingLayout(entries: [])?.pieces(offset: 0, length: 1) == nil)
    }

    @Test
    func manyEntriesAreSearchedNotWalked() throws {
        let entries = (0..<16_384).map { GPUMemoryEntry(address: UInt64($0) * 0x10000, length: 4096) }
        let layout = try #require(BackingLayout(entries: entries))
        #expect(layout.totalLength == 16_384 * 4096)
        #expect(layout.pieces(offset: 16_383 * 4096 + 7, length: 1) == [GuestRange(address: 16_383 * 0x10000 + 7, count: 1)])
        #expect(layout.pieces(offset: 4095, length: 2) == [GuestRange(address: 4095, count: 1), GuestRange(address: 0x10000, count: 1)])
    }
}
