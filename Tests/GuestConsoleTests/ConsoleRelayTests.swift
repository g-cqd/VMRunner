import Foundation
import Testing

@testable import GuestConsole

/// The relay on socket pairs: what reaches the person's terminal with and without the filter, a sequence cut by the relay's
/// own reads, the wake descriptor, and what is written once a session ends.
struct ConsoleRelayTests {
    private struct Session {
        let shown: [UInt8]
        let ending: ConsoleRelay.Ending
    }

    /// The console sends `guestOutput` and closes; the input sends nothing. Returns what reached the terminal's side.
    private func relay(_ guestOutput: [UInt8], filter: ConsoleOutputFilter?) throws -> Session {
        let console = try #require(ConsoleSocket.streamPair(bufferBytes: 256 * 1024))
        let terminal = try #require(ConsoleSocket.streamPair(bufferBytes: 256 * 1024))
        var input: [Int32] = [-1, -1]
        try #require(unsafe pipe(&input) == 0)
        defer {
            for descriptor in input + [console.first, terminal.second] { ConsoleSocket.close(descriptor) }
        }
        // The relay writes to a peer that reads only afterwards: non-blocking, so a regression fails instead of hanging.
        _ = fcntl(terminal.first, F_SETFL, O_NONBLOCK)
        let guest = GuestEnd(descriptor: console.second)
        guest.send(guestOutput)
        guest.close()
        let ending: ConsoleRelay.Ending
        do {
            ending = try ConsoleRelay.run(console: console.first, input: input[0], output: terminal.first, filter: filter)
        } catch {
            ConsoleSocket.close(terminal.first)
            throw error
        }
        ConsoleSocket.close(terminal.first)
        return Session(shown: GuestEnd(descriptor: terminal.second).receive(count: Int.max), ending: ending)
    }

    @Test(.timeLimit(.minutes(1)))
    func theFilterTakesTheGuestsSequencesOutAndKeepsItsText() throws {
        let hostile = "login: \u{1B}]52;c;b3duZWQ=\u{07}\u{1B}[?1049h\u{1B}[6n\u{1B}[1;32mok\u{1B}[0m\r\n"
        let session = try relay(Array(hostile.utf8), filter: ConsoleOutputFilter())
        #expect(session.shown == Array("login: \u{1B}[1;32mok\u{1B}[0m\r\n".utf8))
        #expect(session.ending == .consoleClosed)
    }

    @Test(.timeLimit(.minutes(1)))
    func withoutAFilterEveryByteGoesThroughUnchanged() throws {
        let bytes = Array("\u{1B}]0;title\u{07}\u{1B}[?2004htext".utf8) + [0x9B, 0xFF]
        let session = try relay(bytes, filter: nil)
        #expect(session.shown == bytes)
        #expect(session.ending == .consoleClosed)
    }

    @Test(.timeLimit(.minutes(1)))
    func aSequenceCutByTheRelaysOwnReadsIsStillRemovedWhole() throws {
        // The relay reads at most 16 KiB at a time; the clipboard sequence starts 4 bytes before that boundary.
        let text = [UInt8](repeating: UInt8(ascii: "x"), count: 16 * 1024 - 4)
        let session = try relay(text + Array("\u{1B}]52;c;b3duZWQ=\u{07}done".utf8), filter: ConsoleOutputFilter())
        #expect(session.shown == text + Array("done".utf8))
    }

    @Test(.timeLimit(.minutes(1)))
    func aReadableWakeDescriptorEndsTheRelay() throws {
        let console = try #require(ConsoleSocket.streamPair(bufferBytes: 64 * 1024))
        var input: [Int32] = [-1, -1]
        var wake: [Int32] = [-1, -1]
        var sink: [Int32] = [-1, -1]
        try #require(unsafe pipe(&input) == 0)
        try #require(unsafe pipe(&wake) == 0)
        try #require(unsafe pipe(&sink) == 0)
        defer {
            for descriptor in input + wake + sink + [console.first, console.second] { ConsoleSocket.close(descriptor) }
        }
        var byte: UInt8 = 15
        #expect(unsafe Darwin.write(wake[1], &byte, 1) == 1)
        let ending = try ConsoleRelay.run(
            console: console.first, input: input[0], output: sink[1], filter: ConsoleOutputFilter(), wake: wake[0])
        #expect(ending == .interrupted)
    }

    @Test
    func theResetAfterARawSessionIsMadeOfWhatTheFilterNeverLetsThroughAndAColourReset() {
        var filter = ConsoleOutputFilter()
        let afterRaw = ConsoleRelay.closingBytes(filtered: false)
        #expect(ConsoleRelay.closingBytes(filtered: true) == Array("\u{1B}[0m".utf8))
        #expect(filter.pass(afterRaw[...]) == ConsoleRelay.closingBytes(filtered: true))
        #expect(afterRaw.count > 60)
    }
}
