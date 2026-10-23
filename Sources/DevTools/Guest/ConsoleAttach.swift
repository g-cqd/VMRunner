import Foundation
import GuestConsole

/// `vmr guest console`: this terminal attached to a guest's console. What the guest prints passes through a
/// ``ConsoleOutputFilter`` before it reaches the terminal, unless `raw`. However the session ends (detach, end of input, the
/// console closing, an error, or one of ``SignalWatch/ending``), the terminal's settings come back and what the guest may
/// have left set on the screen is reset: colours after a filtered session, the usual modes as well after a raw one.
enum ConsoleAttach {
    static let rawWarning =
        "warning: --raw passes the guest's output to this terminal unchanged: the guest can set its title, clipboard and modes, "
        + "and make it answer queries"

    static func run(socket: String, raw: Bool) throws -> Int32 {
        if raw { Output.err(rawWarning) }
        Output.err("attached to \(socket); Ctrl-] detaches")
        let watch = SignalWatch(signals: SignalWatch.ending)
        defer { watch?.stop() }
        let ending: ConsoleRelay.Ending
        do {
            ending = try TerminalMode.raw {
                try ConsoleRelay.run(
                    socketPath: socket, input: STDIN_FILENO, output: STDOUT_FILENO, filter: raw ? nil : ConsoleOutputFilter(),
                    wake: watch?.descriptor ?? -1)
            }
        } catch let error as ConsoleError {
            resetScreen(raw: raw)
            throw GuestExec.failure(error)
        }
        resetScreen(raw: raw)
        switch ending {
        case .consoleClosed: Output.err("\nthe console closed")
        case .inputEnded: Output.err("\nend of input")
        case .detached: Output.err("\ndetached")
        case .interrupted:
            let number = watch?.caught() ?? SIGTERM
            Output.err("\nended by signal \(number)")
            return 128 + number
        }
        return 0
    }

    /// Resets what the guest's output may have left set on the terminal; nothing when standard output is not a terminal.
    private static func resetScreen(raw: Bool) {
        guard isatty(STDOUT_FILENO) == 1 else { return }
        try? FileHandle.standardOutput.write(contentsOf: Data(ConsoleRelay.closingBytes(filtered: !raw)))
    }
}
