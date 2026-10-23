import Foundation
import GuestConsole

/// `vmr guest console`: this terminal attached to a guest's console. What the guest prints passes through a
/// ``ConsoleOutputFilter`` before it reaches the terminal, and the colours it may have left set are reset at the end.
enum ConsoleAttach {
    static func run(socket: String) throws -> Int32 {
        Output.err("attached to \(socket); Ctrl-] detaches")
        let ending: ConsoleRelay.Ending
        do {
            ending = try TerminalMode.raw {
                try ConsoleRelay.run(socketPath: socket, input: STDIN_FILENO, output: STDOUT_FILENO, filter: ConsoleOutputFilter())
            }
        } catch let error as ConsoleError {
            resetScreen()
            throw GuestExec.failure(error)
        }
        resetScreen()
        switch ending {
        case .consoleClosed: Output.err("\nthe console closed")
        case .inputEnded: Output.err("\nend of input")
        case .detached: Output.err("\ndetached")
        case .interrupted: Output.err("\ninterrupted")
        }
        return 0
    }

    /// Resets what the guest's output may have left set on the terminal; nothing when standard output is not a terminal.
    private static func resetScreen() {
        guard isatty(STDOUT_FILENO) == 1 else { return }
        try? FileHandle.standardOutput.write(contentsOf: Data(ConsoleRelay.closingBytes(filtered: true)))
    }
}
