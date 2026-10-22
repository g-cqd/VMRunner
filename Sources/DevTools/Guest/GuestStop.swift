import Foundation

/// `vmr guest stop`: ends the helper of a guest started from a scratch directory and clears what it left behind.
struct GuestStop {
    let scratch: GuestScratch
    var grace = Duration.seconds(5)

    func run() async throws {
        guard let record = GuestProcess.read(from: scratch.pidFile) else {
            throw ToolError("no guest is recorded under \(scratch.runDirectory.path) (no readable helper.pid)")
        }
        let outcome = await GuestProcess.stop(record, grace: grace)
        switch outcome {
        case .notRunning:
            Output.out("the helper (pid \(record.pid)) was not running")
        case .stopped:
            Output.out("stopped the helper (pid \(record.pid))")
        case .killed:
            Output.out("the helper (pid \(record.pid)) ignored SIGTERM for \(grace) and was killed")
        }
        // A helper that was killed cannot remove its console socket.
        for leftover in [scratch.socket, scratch.pidFile, scratch.commandPipe] { try? FileManager.default.removeItem(at: leftover) }
    }
}
