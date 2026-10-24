import Testing

@testable import VirtioGPURunnerCore

/// Random and mutated requests: whatever the guest sends, the decoder returns, never traps, and never builds more entries
/// than the limit allows.
struct GPUDecoderRandomTests {
    private static let limits = GPULimits()

    private static func check(_ bytes: [UInt8]) {
        let decoded = GPUDecoder.decode(bytes, limits: limits)
        if bytes.count >= GPUWireSize.header {
            #expect(decoded.header.type == word(bytes, at: 0))
        } else {
            #expect(decoded.header == .unreadable)
        }
        if case .success(.resourceAttachBacking(_, let entries)) = decoded.command {
            #expect(entries.count <= limits.maxBackingEntries)
            #expect(entries.allSatisfy { $0.length > 0 && $0.address.addingReportingOverflow(UInt64($0.length)).overflow == false })
        }
        let answer = GPUResponse.error(.errUnspec).encoded(answering: decoded.header)
        #expect(answer.count == GPUWireSize.header)
    }

    @Test
    func randomBytesOfRandomLengthsDecodeWithoutTrapping() {
        var generator = SeededGenerator(seed: 0x5EED_0001)
        for _ in 0..<3000 {
            let length = Int.random(in: 0...600, using: &generator)
            var bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            // Half of them carry a known type, so the decoder gets past the header.
            if length >= 4, Bool.random(using: &generator), let type = GPUCommandType.allCases.randomElement(using: &generator) {
                for index in 0..<4 { bytes[index] = UInt8(truncatingIfNeeded: type.rawValue >> (8 * index)) }
            }
            Self.check(bytes)
        }
    }

    @Test
    func mutatedWellFormedRequestsDecodeWithoutTrapping() {
        var generator = SeededGenerator(seed: 0x5EED_0002)
        let seeds = GPUDecoderTests.wellFormed.map(\.bytes)
        for round in 0..<3000 {
            var bytes = seeds[round % seeds.count]
            switch Int.random(in: 0..<3, using: &generator) {
            case 0:
                for _ in 0..<Int.random(in: 1...4, using: &generator) {
                    let index = Int.random(in: 0..<bytes.count, using: &generator)
                    bytes[index] = UInt8.random(in: 0...255, using: &generator)
                }
            case 1:
                bytes = Array(bytes.prefix(Int.random(in: 0...bytes.count, using: &generator)))
            default:
                bytes += (0..<Int.random(in: 1...64, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            }
            Self.check(bytes)
        }
    }
}
