@testable import VirtioInput

/// A deterministic generator (xorshift64*), so a random test fails the same way on every run.
struct XorShiftGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x2545_F491_4F6C_DD1D : seed
    }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }
}

/// A buffer of the event queue that records what is done to it.
final class FakeEventBuffer: GuestEventBuffer {
    struct WriteFailure: Error {}

    let writeCapacity: Int
    private let failsToWrite: Bool
    private(set) var written: [[UInt8]] = []
    private(set) var givenBackCount = 0

    init(capacity: Int = InputWire.eventSize, failsToWrite: Bool = false) {
        writeCapacity = capacity
        self.failsToWrite = failsToWrite
    }

    /// The event written, if one was.
    var event: InputEvent? { written.first.flatMap { InputEvent(bytes: $0) } }

    func put(_ bytes: [UInt8]) throws {
        if failsToWrite { throw WriteFailure() }
        written.append(bytes)
    }

    func giveBack() {
        givenBackCount += 1
    }
}

/// A buffer of the status queue that records what is done to it.
final class FakeStatusBuffer: GuestStatusBuffer {
    struct ReadFailure: Error {}

    let byteCount: Int
    private let content: [UInt8]
    private let failsToRead: Bool
    private(set) var takes: [Int] = []
    private(set) var givenBackCount = 0

    /// A buffer the guest claims to have written `byteCount` bytes to; a read returns `content`.
    init(byteCount: Int, content: [UInt8] = [], failsToRead: Bool = false) {
        self.byteCount = byteCount
        self.content = content
        self.failsToRead = failsToRead
    }

    func take(count: Int) throws -> [UInt8] {
        takes.append(count)
        if failsToRead { throw ReadFailure() }
        return Array((content + Array(repeating: 0, count: max(0, count - content.count))).prefix(count))
    }

    func giveBack() {
        givenBackCount += 1
    }
}

/// The events of a frame: `count - 1` key events carrying `tag` as the value, then a report.
func frame(_ count: Int, tag: Int32) -> [InputEvent] {
    (0..<max(count - 1, 0)).map { InputEvent(type: InputEventType.key, code: UInt16($0), value: tag) } + [.report]
}
