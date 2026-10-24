import Testing

@testable import VirtioGPURunnerCore

/// The resource store against the limits and against a guest whose memory and requests are hostile.
struct ResourceStoreTests {
    private static func store(_ configure: (inout GPULimits) -> Void = { _ in }) -> ResourceStore {
        var limits = GPULimits()
        configure(&limits)
        return ResourceStore(limits: limits)
    }

    /// A 4 × 2 resource 1 backed by one 32-byte region at 0x4000 whose bytes are 0, 1, 2, ...
    private static func backedStore() -> (store: ResourceStore, memory: FakeGuestMemory) {
        var store = store()
        var memory = FakeGuestMemory()
        memory.add(at: 0x4000, count: 32)
        _ = store.create2D(resourceID: 1, format: 2, width: 4, height: 2)
        _ = store.attachBacking(1, entries: [GPUMemoryEntry(address: 0x4000, length: 32)])
        return (store, memory)
    }

    @Test
    func createAllocatesAZeroFilledCopyAndCountsIt() throws {
        var store = Self.store()
        #expect(store.create2D(resourceID: 5, format: 67, width: 3, height: 2) == .okNoData)
        let resource = try #require(store.resource(5))
        #expect(resource.pixels == Array(repeating: 0, count: 24) && resource.stride == 12 && resource.format == .r8g8b8a8)
        #expect(store.totalBytes == 24 && store.count == 1)
        #expect(store.unref(5) == .okNoData)
        #expect(store.totalBytes == 0 && store.isEmpty)
        #expect(store.unref(5) == .errInvalidResourceID)
    }

    struct RefusedCreate {
        let id: UInt32
        let format: UInt32
        let size: (width: UInt32, height: UInt32)
        let answer: GPUResponseType

        init(_ id: UInt32, _ format: UInt32, _ width: UInt32, _ height: UInt32, _ answer: GPUResponseType) {
            self.id = id
            self.format = format
            size = (width, height)
            self.answer = answer
        }
    }

    static let refusedCreates: [RefusedCreate] = [
        RefusedCreate(0, 1, 4, 4, .errInvalidResourceID),
        RefusedCreate(1, 0, 4, 4, .errInvalidParameter),
        RefusedCreate(1, 5, 4, 4, .errInvalidParameter),
        RefusedCreate(1, 0xFFFF_FFFF, 4, 4, .errInvalidParameter),
        RefusedCreate(1, 1, 0, 0, .errInvalidParameter),
        RefusedCreate(1, 1, 0, 4, .errInvalidParameter),
        RefusedCreate(1, 1, UInt32.max, 1, .errOutOfMemory),
        RefusedCreate(1, 1, UInt32.max, UInt32.max, .errOutOfMemory),
        RefusedCreate(1, 1, 4097, 4096, .errOutOfMemory),
    ]

    @Test(arguments: 0..<refusedCreates.count)
    func aRefusedCreateAllocatesNothing(row: Int) {
        var store = Self.store()
        let refused = Self.refusedCreates[row]
        #expect(
            store.create2D(resourceID: refused.id, format: refused.format, width: refused.size.width, height: refused.size.height)
                == refused.answer)
        #expect(store.isEmpty && store.totalBytes == 0)
    }

    @Test
    func theLargestResourceFitsAndADuplicateIdIsRefused() {
        var store = Self.store()
        #expect(store.create2D(resourceID: 1, format: 1, width: 4096, height: 4096) == .okNoData)
        #expect(store.create2D(resourceID: 1, format: 1, width: 1, height: 1) == .errInvalidResourceID)
        #expect(store.totalBytes == 64 << 20)
    }

    @Test
    func theCountAndTotalLimitsAnswerOutOfMemory() {
        var store = Self.store()
        for id in 1...256 { #expect(store.create2D(resourceID: UInt32(id), format: 1, width: 1, height: 1) == .okNoData) }
        #expect(store.create2D(resourceID: 257, format: 1, width: 1, height: 1) == .errOutOfMemory)

        var total = Self.store { $0.maxTotalResourceBytes = 100 }
        #expect(total.create2D(resourceID: 1, format: 1, width: 5, height: 5) == .okNoData)
        #expect(total.create2D(resourceID: 2, format: 1, width: 1, height: 1) == .errOutOfMemory)
        #expect(total.unref(1) == .okNoData)
        #expect(total.create2D(resourceID: 2, format: 1, width: 5, height: 5) == .okNoData)
    }

    @Test
    func backingIsAttachedOnceAndDetachedOnce() {
        var store = Self.store()
        let entries = [GPUMemoryEntry(address: 0x4000, length: 64)]
        #expect(store.attachBacking(1, entries: entries) == .errInvalidResourceID)
        _ = store.create2D(resourceID: 1, format: 1, width: 4, height: 4)
        #expect(store.detachBacking(1) == .errUnspec)
        #expect(store.attachBacking(1, entries: [GPUMemoryEntry(address: UInt64.max, length: 2)]) == .errInvalidParameter)
        #expect(store.attachBacking(1, entries: entries) == .okNoData)
        #expect(store.attachBacking(1, entries: entries) == .errUnspec)
        #expect(store.detachBacking(1) == .okNoData)
        #expect(store.detachBacking(1) == .errUnspec)
        #expect(store.detachBacking(2) == .errInvalidResourceID)
    }

    @Test
    func aTransferCopiesTheRectangleFromItsOffset() throws {
        var (store, memory) = Self.backedStore()
        // Row 1, pixels 1 and 2: offset = 1 × 16 + 1 × 4.
        #expect(
            store.transferToHost2D(resourceID: 1, rect: GPURect(x: 1, y: 1, width: 2, height: 1), offset: 20, memory: memory) == .okNoData)
        let pixels = try #require(store.resource(1)).pixels
        #expect(Array(pixels[20..<28]) == Array(20..<28))
        #expect(pixels[0..<20].allSatisfy { $0 == 0 } && pixels[28...].allSatisfy { $0 == 0 })

        memory = FakeGuestMemory()
        memory.add(at: 0x4000, count: 32, seed: 100)
        #expect(
            store.transferToHost2D(resourceID: 1, rect: GPURect(x: 0, y: 0, width: 4, height: 2), offset: 0, memory: memory) == .okNoData)
        #expect(try #require(store.resource(1)).pixels == (0..<32).map { UInt8($0 + 100) })
    }

    @Test
    func aTransferAcrossEntriesReadsEachPiece() throws {
        var store = Self.store()
        var memory = FakeGuestMemory()
        memory.add(at: 0x8000, count: 12, seed: 0)
        memory.add(at: 0x2000, count: 20, seed: 12)
        _ = store.create2D(resourceID: 1, format: 1, width: 4, height: 2)
        _ = store.attachBacking(1, entries: [GPUMemoryEntry(address: 0x8000, length: 12), GPUMemoryEntry(address: 0x2000, length: 20)])
        #expect(
            store.transferToHost2D(resourceID: 1, rect: GPURect(x: 0, y: 0, width: 4, height: 2), offset: 0, memory: memory) == .okNoData)
        #expect(try #require(store.resource(1)).pixels == Array(0..<32))
    }

    struct RefusedTransfer {
        let rect: GPURect
        let offset: UInt64
        let answer: GPUResponseType

        init(_ rect: GPURect, _ offset: UInt64, _ answer: GPUResponseType) {
            self.rect = rect
            self.offset = offset
            self.answer = answer
        }
    }

    static let refusedTransfers: [RefusedTransfer] = [
        RefusedTransfer(GPURect(x: 0, y: 0, width: 5, height: 1), 0, .errInvalidParameter),
        RefusedTransfer(GPURect(x: 4, y: 0, width: 1, height: 1), 0, .errInvalidParameter),
        RefusedTransfer(GPURect(x: 0, y: 2, width: 1, height: 1), 0, .errInvalidParameter),
        RefusedTransfer(GPURect(x: UInt32.max, y: 0, width: 2, height: 1), 0, .errInvalidParameter),
        RefusedTransfer(GPURect(x: 0, y: 0, width: 4, height: 2), 1, .errInvalidParameter),
        RefusedTransfer(GPURect(x: 0, y: 0, width: 1, height: 1), 29, .errInvalidParameter),
        RefusedTransfer(GPURect(x: 0, y: 0, width: 1, height: 1), UInt64.max, .errInvalidParameter),
        RefusedTransfer(GPURect(x: 0, y: 0, width: 1, height: 2), UInt64.max - 15, .errInvalidParameter),
    ]

    @Test(arguments: 0..<refusedTransfers.count)
    func aRefusedTransferChangesNothing(row: Int) throws {
        var (store, memory) = Self.backedStore()
        let refused = Self.refusedTransfers[row]
        #expect(store.transferToHost2D(resourceID: 1, rect: refused.rect, offset: refused.offset, memory: memory) == refused.answer)
        #expect(try #require(store.resource(1)).pixels.allSatisfy { $0 == 0 })
    }

    @Test
    func aTransferFromMemoryThatIsNotRAMChangesNothing() throws {
        var store = Self.store()
        var memory = FakeGuestMemory()
        memory.add(at: 0x4000, count: 16, seed: 1)
        _ = store.create2D(resourceID: 1, format: 1, width: 4, height: 2)
        // The second row lies outside guest RAM: the first row, already read, must not be written either.
        _ = store.attachBacking(
            1, entries: [GPUMemoryEntry(address: 0x4000, length: 16), GPUMemoryEntry(address: 0xDEAD_0000, length: 16)])
        #expect(
            store.transferToHost2D(resourceID: 1, rect: GPURect(x: 0, y: 0, width: 4, height: 2), offset: 0, memory: memory) == .errUnspec)
        #expect(try #require(store.resource(1)).pixels.allSatisfy { $0 == 0 })
    }

    @Test
    func overlappingEntriesAreReadAsTheyAre() throws {
        var store = Self.store()
        var memory = FakeGuestMemory()
        memory.add(at: 0x4000, count: 16)
        _ = store.create2D(resourceID: 1, format: 1, width: 4, height: 2)
        _ = store.attachBacking(1, entries: [GPUMemoryEntry(address: 0x4000, length: 16), GPUMemoryEntry(address: 0x4000, length: 16)])
        #expect(
            store.transferToHost2D(resourceID: 1, rect: GPURect(x: 0, y: 0, width: 4, height: 2), offset: 0, memory: memory) == .okNoData)
        #expect(try #require(store.resource(1)).pixels == Array(0..<16) + Array(0..<16))
    }

    @Test
    func aTransferNeedsAKnownResourceWithBacking() {
        var (store, memory) = Self.backedStore()
        let rect = GPURect(x: 0, y: 0, width: 1, height: 1)
        #expect(store.transferToHost2D(resourceID: 0, rect: rect, offset: 0, memory: memory) == .errInvalidResourceID)
        #expect(store.transferToHost2D(resourceID: 9, rect: rect, offset: 0, memory: memory) == .errInvalidResourceID)
        _ = store.detachBacking(1)
        #expect(store.transferToHost2D(resourceID: 1, rect: rect, offset: 0, memory: memory) == .errUnspec)
        _ = store.attachBacking(1, entries: [GPUMemoryEntry(address: 0x4000, length: 32)])
        memory = FakeGuestMemory()
        #expect(
            store.transferToHost2D(resourceID: 1, rect: GPURect(x: 0, y: 0, width: 0, height: 1), offset: 0, memory: memory) == .okNoData)
    }

    @Test
    func removeAllForgetsEveryResource() {
        var (store, _) = Self.backedStore()
        store.removeAll()
        #expect(store.isEmpty && store.totalBytes == 0 && store.resource(1) == nil)
    }
}
