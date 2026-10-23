import Testing

@testable import ControlProtocol

/// Lines come out whole and in order, and a line past the limit is refused whether or not its newline has arrived.
struct LineBufferTests {
    @Test
    func linesComeOutOneByOneAndAPartialLineWaits() {
        var buffer = LineBuffer(limit: 16)
        buffer.append(Array("ab\ncd\nef".utf8))
        #expect(buffer.next() == .line(Array("ab".utf8)))
        #expect(buffer.next() == .line(Array("cd".utf8)))
        #expect(buffer.next() == .needMore)
        buffer.append(Array("g\n".utf8))
        #expect(buffer.next() == .line(Array("efg".utf8)))
        #expect(buffer.next() == .needMore)
        #expect(buffer.pendingCount == 0)
    }

    @Test
    func aLineOfExactlyTheLimitPassesAndOneByteMoreIsTooLong() {
        var exact = LineBuffer(limit: 4)
        exact.append(Array("abcd\n".utf8))
        #expect(exact.next() == .line(Array("abcd".utf8)))
        var over = LineBuffer(limit: 4)
        over.append(Array("abcde\n".utf8))
        #expect(over.next() == .tooLong)
    }

    @Test
    func anUnfinishedLinePastTheLimitIsTooLongWithoutWaitingForItsNewline() {
        var buffer = LineBuffer(limit: 4)
        buffer.append(Array("abcde".utf8))
        #expect(buffer.next() == .tooLong)
    }

    @Test
    func theStandardLimitsAreTheOnesTheDecisionStates() {
        let limits = ControlLimits()
        #expect(limits.requestBytes == 65_536 && limits.connections == 4 && limits.requestsPerConnection == 64)
        #expect(limits.readTimeoutMilliseconds == 10_000 && limits.writeStallMilliseconds == 2_000)
        #expect(limits.requestTimeout == .seconds(120))
    }
}
