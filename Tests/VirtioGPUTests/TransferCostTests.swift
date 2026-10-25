import Testing

@testable import VirtioGPU

/// Guest memory that counts the copies asked of it.
private struct CountingGuestMemory: GuestMemoryReader {
    final class Counter {
        var calls = 0
        var bytes = 0
    }

    let base: FakeGuestMemory
    let counter = Counter()

    func copyBytes(atPhysicalAddress address: UInt64, count: Int) -> [UInt8]? {
        counter.calls += 1
        counter.bytes += count
        return base.copyBytes(atPhysicalAddress: address, count: count)
    }
}

/// What a transfer costs the main queue, which the app's device runs on: the number of copies asked of guest memory follows
/// the pieces of the backing, not the rows of the picture.
struct TransferCostTests {
    /// A resource of `width` × `height` pixels whose backing is `pieces` regions of equal size, at addresses that do not touch.
    private static func resource(width: UInt32, height: UInt32, pieces: Int) -> (store: ResourceStore, memory: CountingGuestMemory) {
        var store = ResourceStore(limits: GPULimits())
        var memory = FakeGuestMemory()
        let total = Int(width) * Int(height) * GPUPixelFormat.bytesPerPixel
        var entries: [GPUMemoryEntry] = []
        for index in 0..<pieces {
            let address = 0x1000_0000 + UInt64(index) * 0x10_0000
            memory.add(at: address, count: total / pieces, seed: UInt8(truncatingIfNeeded: index))
            entries.append(GPUMemoryEntry(address: address, length: UInt32(total / pieces)))
        }
        _ = store.create2D(resourceID: 1, format: 2, width: width, height: height)
        _ = store.attachBacking(1, entries: entries)
        return (store, CountingGuestMemory(base: memory))
    }

    /// The bytes of the backing, end to end, as `resource(width:height:pieces:)` fills them.
    private static func image(count: Int, pieces: Int) -> [UInt8] {
        (0..<pieces).flatMap { piece in
            (0..<count / pieces).map { UInt8(truncatingIfNeeded: $0) &+ UInt8(truncatingIfNeeded: piece) }
        }
    }

    @Test
    func aFullWidthFrameInOneRegionIsOneCopy() throws {
        let (initial, memory) = Self.resource(width: 1280, height: 800, pieces: 1)
        var store = initial
        let frame = GPURect(x: 0, y: 0, width: 1280, height: 800)
        #expect(store.transferToHost2D(resourceID: 1, rect: frame, offset: 0, memory: memory) == .okNoData)
        #expect(memory.counter.calls == 1, "800 rows are one span")
        #expect(memory.counter.bytes == 1280 * 800 * 4)
        #expect(try #require(store.resource(1)).pixels == Self.image(count: 1280 * 800 * 4, pieces: 1))
    }

    @Test
    func aFullWidthFrameInPagesIsOneCopyPerPage() throws {
        let (initial, memory) = Self.resource(width: 1280, height: 800, pieces: 1000)
        var store = initial
        let frame = GPURect(x: 0, y: 0, width: 1280, height: 800)
        #expect(store.transferToHost2D(resourceID: 1, rect: frame, offset: 0, memory: memory) == .okNoData)
        #expect(memory.counter.calls == 1000, "one copy per piece of the backing, not per row")
        #expect(try #require(store.resource(1)).pixels == Self.image(count: 1280 * 800 * 4, pieces: 1000))
    }

    @Test
    func someFullWidthRowsInTheMiddleAreCopiedAsOneSpanToTheirPlace() throws {
        let (initial, memory) = Self.resource(width: 8, height: 8, pieces: 1)
        var store = initial
        // Rows 3 and 4: the driver's offset is 3 × 32.
        let rows = GPURect(x: 0, y: 3, width: 8, height: 2)
        #expect(store.transferToHost2D(resourceID: 1, rect: rows, offset: 96, memory: memory) == .okNoData)
        #expect(memory.counter.calls == 1)
        let pixels = try #require(store.resource(1)).pixels
        #expect(Array(pixels[96..<160]) == Array(Self.image(count: 256, pieces: 1)[96..<160]))
        #expect(pixels[..<96].allSatisfy { $0 == 0 } && pixels[160...].allSatisfy { $0 == 0 })
    }

    @Test
    func aNarrowerRectangleIsOneCopyPerRowAndLandsInItsColumns() throws {
        let (initial, memory) = Self.resource(width: 64, height: 32, pieces: 1)
        var store = initial
        // 16 pixels wide from column 8, on rows 4 to 11: the offset counts 4 × 256 + 8 × 4.
        let rect = GPURect(x: 8, y: 4, width: 16, height: 8)
        #expect(store.transferToHost2D(resourceID: 1, rect: rect, offset: 1056, memory: memory) == .okNoData)
        #expect(memory.counter.calls == 8)
        #expect(memory.counter.bytes == 16 * 4 * 8, "only the rectangle's bytes are read")
        let pixels = try #require(store.resource(1)).pixels
        let image = Self.image(count: 64 * 32 * 4, pieces: 1)
        for row in 4..<12 {
            let start = row * 256 + 32
            #expect(Array(pixels[start..<start + 64]) == Array(image[start..<start + 64]))
        }
        #expect(pixels.filter { $0 != 0 }.count <= 64 * 8, "nothing outside the rectangle was written")
        #expect(pixels[..<(4 * 256)].allSatisfy { $0 == 0 })
    }

    @Test
    func aNarrowerRectangleOfMoreRowsThanTheLimitIsRefusedBeforeAnyRead() throws {
        let (initial, memory) = Self.resource(width: 2, height: 9000, pieces: 1)
        var store = initial
        let tooTall = GPURect(x: 0, y: 0, width: 1, height: UInt32(GPULimits().maxTransferRows + 1))
        #expect(store.transferToHost2D(resourceID: 1, rect: tooTall, offset: 0, memory: memory) == .errInvalidParameter)
        #expect(memory.counter.calls == 0)
        #expect(try #require(store.resource(1)).pixels.allSatisfy { $0 == 0 })

        let atTheLimit = GPURect(x: 0, y: 0, width: 1, height: UInt32(GPULimits().maxTransferRows))
        #expect(store.transferToHost2D(resourceID: 1, rect: atTheLimit, offset: 0, memory: memory) == .okNoData)
        #expect(memory.counter.calls == GPULimits().maxTransferRows)
    }

    @Test
    func aFullWidthRectangleOfMoreRowsThanTheLimitIsStillOneCopy() throws {
        let (initial, memory) = Self.resource(width: 1, height: 20_000, pieces: 1)
        var store = initial
        let column = GPURect(x: 0, y: 0, width: 1, height: 20_000)
        #expect(store.transferToHost2D(resourceID: 1, rect: column, offset: 0, memory: memory) == .okNoData)
        #expect(memory.counter.calls == 1)
        #expect(try #require(store.resource(1)).pixels == Self.image(count: 20_000 * 4, pieces: 1))
    }

    @Test
    func aFullWidthTransferWhoseLastPieceCannotBeReadWritesNothing() throws {
        var store = ResourceStore(limits: GPULimits())
        var memory = FakeGuestMemory()
        memory.add(at: 0x4000, count: 64, seed: 1)
        _ = store.create2D(resourceID: 1, format: 2, width: 4, height: 8)
        // Half of the picture is in RAM, the other half is not: the rows already read must not be written.
        _ = store.attachBacking(
            1, entries: [GPUMemoryEntry(address: 0x4000, length: 64), GPUMemoryEntry(address: 0xDEAD_0000, length: 64)])
        let counting = CountingGuestMemory(base: memory)
        let all = GPURect(x: 0, y: 0, width: 4, height: 8)
        #expect(store.transferToHost2D(resourceID: 1, rect: all, offset: 0, memory: counting) == .errUnspec)
        #expect(counting.counter.calls == 2, "the copy stops at the first piece that cannot be read")
        #expect(try #require(store.resource(1)).pixels.allSatisfy { $0 == 0 })
    }

    @Test
    func aFullWidthSpanThatEndsPastTheBackingIsRefusedBeforeAnyRead() throws {
        let (initial, memory) = Self.resource(width: 1280, height: 800, pieces: 1)
        var store = initial
        let frame = GPURect(x: 0, y: 0, width: 1280, height: 800)
        #expect(store.transferToHost2D(resourceID: 1, rect: frame, offset: 1, memory: memory) == .errInvalidParameter)
        #expect(store.transferToHost2D(resourceID: 1, rect: frame, offset: UInt64.max, memory: memory) == .errInvalidParameter)
        #expect(memory.counter.calls == 0)
        #expect(try #require(store.resource(1)).pixels.allSatisfy { $0 == 0 })
    }
}
