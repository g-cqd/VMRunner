import Testing

@testable import VirtioGPU

/// Random and mutated requests through the whole device: it never traps, every answer is a well-formed answer of a known
/// type and size, and the host copies never exceed the limit.
struct GPUDeviceStateRandomTests {
    private static let knownTypes = Set(GPUResponseType.allCases.map(\.rawValue))

    private static func limits() -> GPULimits {
        var limits = GPULimits()
        limits.maxResources = 8
        limits.maxResourceBytes = 64 * 64 * 4
        limits.maxTotalResourceBytes = 3 * 64 * 64 * 4
        return limits
    }

    private static func check(_ handled: HandledCommand, queue: GPUQueueKind, state: GPUDeviceState) {
        if queue == .cursor {
            #expect(handled.response == nil)
        } else if let answer = handled.response {
            let type = word(answer, at: 0)
            #expect(Self.knownTypes.contains(type))
            #expect(answer.count == (type == GPUResponseType.okDisplayInfo.rawValue ? GPUWireSize.displayInfo : GPUWireSize.header))
        } else {
            Issue.record("a control request got no answer")
        }
        #expect(state.store.totalBytes <= state.store.limits.maxTotalResourceBytes)
        #expect(state.store.count <= state.store.limits.maxResources)
    }

    /// A request that is valid in shape, with small random values, so the store is exercised and not only the decoder.
    private static func plausible(using generator: inout SeededGenerator) -> [UInt8] {
        let small = { (generator: inout SeededGenerator) in UInt32.random(in: 0...70, using: &generator) }
        switch Int.random(in: 0..<7, using: &generator) {
        case 0: return request(.resourceCreate2D, words: [small(&generator) % 6, 2, small(&generator), small(&generator)])
        case 1:
            let count = Int.random(in: 0...3, using: &generator)
            let entries = (0..<count).map { _ in (UInt64(0x4000 + small(&generator) * 64), UInt32(small(&generator) * 256)) }
            return request(.resourceAttachBacking, words: [small(&generator) % 6, UInt32(count)], tail: entryBytes(entries))
        case 2:
            let rect = GPURect(x: small(&generator), y: small(&generator), width: small(&generator), height: small(&generator))
            return transfer(rect, offset: UInt64(small(&generator)) * 4, resource: small(&generator) % 6)
        case 3: return request(.setScanout, words: [0, 0, small(&generator), small(&generator), 0, small(&generator) % 6])
        case 4: return request(.resourceFlush, words: [0, 0, small(&generator), small(&generator), small(&generator) % 6, 0])
        case 5: return request(.resourceUnref, words: [small(&generator) % 6, 0])
        default: return request(.resourceDetachBacking, words: [small(&generator) % 6, 0])
        }
    }

    @Test
    func randomBytesOnBothQueuesAreAnsweredWellFormed() {
        var generator = SeededGenerator(seed: 0x5EED_0003)
        var state = GPUDeviceState(limits: Self.limits())
        var memory = FakeGuestMemory()
        memory.add(at: 0x4000, count: 64 * 1024)
        for _ in 0..<2500 {
            let length = Int.random(in: 0...600, using: &generator)
            var bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            if length >= 4, let type = GPUCommandType.allCases.randomElement(using: &generator) {
                for index in 0..<4 { bytes[index] = UInt8(truncatingIfNeeded: type.rawValue >> (8 * index)) }
            }
            let queue: GPUQueueKind = Bool.random(using: &generator) ? .control : .cursor
            Self.check(state.handle(bytes, queue: queue, memory: memory), queue: queue, state: state)
        }
    }

    @Test
    func plausibleAndMutatedSequencesKeepTheStoreWithinItsLimits() {
        var generator = SeededGenerator(seed: 0x5EED_0004)
        var state = GPUDeviceState(limits: Self.limits())
        var memory = FakeGuestMemory()
        memory.add(at: 0x4000, count: 64 * 1024, seed: 7)
        for round in 0..<3000 {
            var bytes = Self.plausible(using: &generator)
            if round.isMultiple(of: 3) {
                let index = Int.random(in: 0..<bytes.count, using: &generator)
                bytes[index] = UInt8.random(in: 0...255, using: &generator)
            }
            let handled = state.handle(bytes, queue: .control, memory: memory)
            Self.check(handled, queue: .control, state: state)
            if let update = handled.scanoutUpdate {
                #expect(update.pixels.count == Int(update.width) * Int(update.height) * 4)
            }
            if (round + 1).isMultiple(of: 500) { state.reset() }
        }
    }
}
