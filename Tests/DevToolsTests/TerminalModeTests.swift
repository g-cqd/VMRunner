import Foundation
import Testing

@testable import DevTools

/// Raw mode on a real pseudo-terminal pair, and the signal watch, without a guest.
struct TerminalModeTests {
    private struct Failure: Error {}

    /// A fresh pseudo-terminal pair; `body` gets the terminal's end.
    private func withTerminal(_ body: (Int32) throws -> Void) throws {
        var controller: Int32 = -1
        var terminal: Int32 = -1
        try #require(unsafe openpty(&controller, &terminal, nil, nil, nil) == 0)
        defer {
            close(terminal)
            close(controller)
        }
        try body(terminal)
    }

    private func settings(_ descriptor: Int32) -> termios {
        var current = termios()
        _ = unsafe tcgetattr(descriptor, &current)
        return current
    }

    /// The kernel sets PENDIN (retype pending input) when a terminal leaves raw mode, so that flag is left out of the comparison.
    /// The control characters and the line speeds are compared as well.
    private func sameFlags(_ lhs: termios, _ rhs: termios) -> Bool {
        let pending = tcflag_t(PENDIN)
        var left = lhs
        var right = rhs
        let leftControls = withUnsafeBytes(of: lhs.c_cc) { unsafe Array($0) }
        let rightControls = withUnsafeBytes(of: rhs.c_cc) { unsafe Array($0) }
        let controls = leftControls == rightControls
        let speeds = unsafe cfgetispeed(&left) == cfgetispeed(&right) && cfgetospeed(&left) == cfgetospeed(&right)
        return lhs.c_iflag == rhs.c_iflag && lhs.c_oflag == rhs.c_oflag && lhs.c_cflag == rhs.c_cflag
            && lhs.c_lflag & ~pending == rhs.c_lflag & ~pending && controls && speeds
    }

    @Test
    func rawModeHoldsWhileTheBodyRunsAndTheOriginalSettingsComeBackAfter() throws {
        try withTerminal { terminal in
            let before = settings(terminal)
            #expect(before.c_lflag & tcflag_t(ICANON) != 0, "a new pseudo-terminal starts in canonical mode")
            let during = TerminalMode.raw(on: terminal) { settings(terminal) }
            #expect(during.c_lflag & tcflag_t(ICANON | ECHO | ISIG) == 0)
            #expect(!sameFlags(during, before))
            #expect(sameFlags(settings(terminal), before))
        }
    }

    @Test
    func theOriginalSettingsComeBackWhenTheBodyThrows() throws {
        try withTerminal { terminal in
            let before = settings(terminal)
            #expect(throws: Failure.self) {
                try TerminalMode.raw(on: terminal) {
                    #expect(settings(terminal).c_lflag & tcflag_t(ECHO) == 0)
                    throw Failure()
                }
            }
            #expect(sameFlags(settings(terminal), before))
        }
    }

    @Test
    func aDescriptorThatIsNotATerminalIsLeftAlone() throws {
        var ends: [Int32] = [-1, -1]
        try #require(unsafe pipe(&ends) == 0)
        defer { for end in ends { close(end) } }
        #expect(TerminalMode.raw(on: ends[0]) { 42 } == 42)
    }

    /// SIGUSR1 stands in for the signals the console watches: the same path, and nothing else in the test process uses it.
    @Test(.timeLimit(.minutes(1)))
    func aWatchedSignalBecomesAByteOnThePipeAndDoesNotEndTheProcess() throws {
        let watch = try #require(SignalWatch(signals: [SIGUSR1]))
        defer { watch.stop() }
        // The source starts listening shortly after it is made, so the signal is sent until the pipe answers.
        var arrived = false
        for _ in 0..<100 where !arrived {
            kill(getpid(), SIGUSR1)
            var entry = pollfd(fd: watch.descriptor, events: Int16(POLLIN), revents: 0)
            arrived = unsafe poll(&entry, 1, 100) == 1
        }
        #expect(arrived)
        #expect(watch.caught() == SIGUSR1)
    }

    @Test
    func aStoppedWatchReadsNothing() throws {
        let watch = try #require(SignalWatch(signals: [SIGUSR1]))
        watch.stop()
        #expect(watch.caught() == nil)
    }

    @Test
    func theWatchedSignalsAreTheFiveTheConsoleClientEndsOn() {
        #expect(SignalWatch.ending == [SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGTERM])
    }
}
