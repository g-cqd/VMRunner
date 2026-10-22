import Foundation
import Synchronization

@testable import GuestConsole

/// What a shell on a terminal prints for a line the exec protocol typed.
enum TerminalShell {
    /// The terminal's answer to `line`: the echoed line, the start marker, the command's output (CRLF line ends), the end marker
    /// with the status, and the next prompt. `nil` when `line` is not an exec line. `run` plays the command.
    static func reply(to line: String, echo: Bool = true, run: (String) -> (output: String, status: Int)) -> String? {
        let prefix = "echo MARK_S_"
        let suffix = "; echo MARK_E_"
        guard line.hasPrefix(prefix), let end = line.range(of: suffix, options: .backwards) else { return nil }
        let afterPrefix = line.dropFirst(prefix.count)
        guard let separator = afterPrefix.firstIndex(of: ";") else { return nil }
        let nonce = afterPrefix[..<separator]
        let command = afterPrefix[afterPrefix.index(separator, offsetBy: 2)..<end.lowerBound]
        let outcome = run(String(command))
        var text = echo ? line.replacing("\n", with: "\r\n") : ""
        text += "MARK_S_\(nonce)\r\n" + outcome.output.replacing("\n", with: "\r\n") + "MARK_E_\(nonce)_\(outcome.status)\r\n"
        return text + "localhost:~# "
    }
}

/// A fake guest: a getty that takes any user name, then a shell that answers exec lines through `TerminalShell`, on one thread.
final class ShellEmulator: Sendable {
    private final class Flag: Sendable {
        let raised = Mutex(false)
    }

    private let stopRequested = Flag()

    /// Starts the thread, which first prints the login prompt. `run` plays each command.
    init(guest: GuestEnd, echo: Bool = true, run: @escaping @Sendable (String) -> (output: String, status: Int)) {
        let stopRequested = stopRequested
        let thread = Thread {
            guest.send("Welcome to the fake guest\r\nlocalhost login: ")
            var loggedIn = false
            var pending: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while !stopRequested.raised.withLock({ $0 }) {
                guard ConsoleSocket.wait(guest.descriptor, milliseconds: 20) else { continue }
                guard case .transferred(let count) = ConsoleSocket.read(guest.descriptor, into: &buffer) else { break }
                pending.append(contentsOf: buffer[0..<count])
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = lossyText(pending[0...newline])
                    pending.removeSubrange(0...newline)
                    if !loggedIn {
                        loggedIn = true
                        guest.send("\(line.dropLast())\r\nlocalhost:~# ")
                    } else if let reply = TerminalShell.reply(to: line, echo: echo, run: run) {
                        guest.send(reply)
                    } else {
                        guest.send(echo ? line.replacing("\n", with: "\r\n") : "")
                        guest.send("localhost:~# ")
                    }
                }
            }
        }
        thread.name = "GuestConsoleTests.ShellEmulator"
        thread.start()
    }

    /// Asks the thread to end; it notices within 20 ms, or at once when the guest end is closed.
    func shutdown() {
        stopRequested.raised.withLock { $0 = true }
    }
}
