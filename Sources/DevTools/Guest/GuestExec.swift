import Foundation
import GuestConsole

/// `vmr guest exec`: one command through a guest's console, with its output and exit status.
struct GuestExec {
    /// `timeout(1)`'s status for a command that ran out of time, and the status for everything else that went wrong on this
    /// side (no console, no login, a console that closed). A status below 124 is the guest command's own.
    static let timeoutStatus: Int32 = 124
    static let failureStatus: Int32 = 125

    let socket: String
    let command: String
    var user = "root"
    var timeout = Duration.seconds(60)
    /// How long to keep trying while the console has another client: the bridge notices a client that left a moment later.
    var busyWait = Duration.seconds(3)
    var loginTimeout = Duration.seconds(30)

    func run() async throws -> ExecResult {
        let session = try await attach()
        defer { session.close() }
        do {
            let prompt = try session.waitForPrompt(timeout: loginTimeout)
            if prompt != .shell { try session.login(user: user, timeout: loginTimeout) }
            return try session.run(command, timeout: timeout)
        } catch let error as ConsoleError {
            throw Self.failure(error)
        }
    }

    /// Connects, retrying for `busyWait` while the console says it has a client.
    private func attach() async throws -> ConsoleSession {
        let clock = ContinuousClock()
        let deadline = clock.now + busyWait
        while true {
            do {
                let session = try ConsoleSession.connect(to: socket)
                // A busy console answers with one line and closes; the first wait shows it.
                do {
                    _ = try session.waitForPrompt(timeout: loginTimeout)
                    return session
                } catch ConsoleError.busy {
                    session.close()
                    guard clock.now < deadline else { throw ConsoleError.busy }
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch let error as ConsoleError {
                throw Self.failure(error)
            }
        }
    }

    static func failure(_ error: ConsoleError) -> ToolError {
        if case .timedOut = error { return ToolError("\(error)", status: timeoutStatus) }
        return ToolError("\(error)", status: failureStatus)
    }
}
