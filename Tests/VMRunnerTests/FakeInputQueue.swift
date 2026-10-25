import Foundation

@testable import VirtioGPU

/// A queue element of the input device that records what is done to it.
final class FakeQueueElement: QueueElement {
    struct Failure: Error {}

    let readableByteCount: Int
    let writableByteCount: Int
    private let content: [UInt8]
    private let failsToWrite: Bool
    private let failsToRead: Bool
    private(set) var written: [[UInt8]] = []
    private(set) var reads: [Int] = []
    private(set) var givenBackCount = 0

    /// A buffer the guest posted for events: `room` bytes to write, nothing to read.
    init(room: Int = 8, failsToWrite: Bool = false) {
        (readableByteCount, writableByteCount, content, self.failsToWrite, failsToRead) = (0, room, [], failsToWrite, false)
    }

    /// A message the guest wrote to the status queue: `length` bytes claimed, `content` read back.
    init(wrote length: Int, content: [UInt8] = [], failsToRead: Bool = false) {
        (readableByteCount, writableByteCount, self.content, failsToWrite, self.failsToRead) = (length, 0, content, false, failsToRead)
    }

    func read(count: Int) throws -> [UInt8] {
        reads.append(count)
        if failsToRead { throw Failure() }
        return Array((content + Array(repeating: 0, count: max(0, count - content.count))).prefix(count))
    }

    func write(_ bytes: [UInt8]) throws {
        if failsToWrite { throw Failure() }
        written.append(bytes)
    }

    func giveBack() {
        givenBackCount += 1
    }
}

/// A queue that hands out the elements it is given, once each, in order.
final class FakeInputQueue: ElementQueue {
    private var waiting: [FakeQueueElement]

    init(_ elements: [FakeQueueElement]) {
        waiting = elements
    }

    func nextElement() -> FakeQueueElement? {
        waiting.isEmpty ? nil : waiting.removeFirst()
    }
}
