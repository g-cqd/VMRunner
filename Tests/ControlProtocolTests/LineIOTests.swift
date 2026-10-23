import Foundation
import Testing

@testable import ControlProtocol

/// Writing an answer: a reader that never takes it cannot hold the answer past its total.
struct LineIOTests {
    @Test
    func aWholeAnswerIsDroppedWhenItsTotalPassesBeforeTheReaderTakesIt() async throws {
        let pair = try ControlClient.connectedPair()
        defer {
            pair.client.close()
            ControlClient(descriptor: pair.server).close()
        }
        // The writing end is non-blocking, as an accepted connection is: a blocking write would wait for the reader forever.
        let server = pair.server
        _ = fcntl(server, F_SETFL, fcntl(server, F_GETFL) | O_NONBLOCK)
        // Far more than the socket buffers hold, and the reader never reads.
        let answer = Data(repeating: UInt8(ascii: "x"), count: 4 * 1_024 * 1_024)
        let started = ContinuousClock.now
        let written = await runOnThread { LineIO.write(answer, to: server, stallMilliseconds: 10_000, totalMilliseconds: 300) }
        #expect(!written)
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
