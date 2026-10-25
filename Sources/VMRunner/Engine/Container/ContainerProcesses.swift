import Foundation
import Synchronization

/// The parts of one runner process that can be reached from any thread: the stop request, the signals and the question
/// whether it still runs. The registry holds one per live runner so the app can end them when it quits, even while the main
/// actor is busy ending the app.
final class RunnerHandle: Sendable {
    let process: Process
    /// The write end of the runner's standard input, until it is closed. Non-blocking, and a write to a runner that is gone
    /// returns an error instead of raising SIGPIPE.
    private let stdin: Mutex<FileHandle?>
    private let ledger: DescriptorLedger

    /// Makes `stdin` non-blocking: the runner may never read it, and a full pipe must not block the app. Closing it is counted in
    /// `ledger`.
    init?(process: Process, stdin: FileHandle, ledger: DescriptorLedger = DescriptorLedger()) {
        let flags = fcntl(stdin.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(stdin.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0,
            fcntl(stdin.fileDescriptor, F_SETNOSIGPIPE, 1) == 0
        else { return nil }
        self.process = process
        self.stdin = Mutex(stdin)
        self.ledger = ledger
    }

    var isRunning: Bool { process.isRunning }

    /// Writes the `stop` line and closes the runner's standard input. A second call does nothing.
    func requestStop() {
        stdin.withLock { handle in
            guard let open = handle else { return }
            handle = nil
            let line = Array("stop\n".utf8)
            _ = line.withUnsafeBytes { unsafe write(open.fileDescriptor, $0.baseAddress, $0.count) }
            try? open.close()
            ledger.closed()
        }
    }

    /// Closes the runner's standard input without a request: the runner reads the end as a request to stop.
    func closeStdin() {
        stdin.withLock { handle in
            guard let open = handle else { return }
            handle = nil
            try? open.close()
            ledger.closed()
        }
    }

    /// SIGTERM, when the runner still runs. The check and the signal are two steps and Foundation reaps the child on its own, so
    /// the pid could in principle be reused in between. macOS hands out pids in sequence and wraps only after a full cycle, so a
    /// reuse within these few instructions does not happen in practice; the same goes for `forceKill()`.
    func terminate() {
        if process.isRunning { process.terminate() }
    }

    /// SIGKILL, when the runner still runs.
    func forceKill() {
        if process.isRunning { _ = Foundation.kill(process.processIdentifier, SIGKILL) }
    }
}

/// Every container runner that is running, in this process. The app ends them when it quits: a runner also ends by itself when
/// the end of its standard input arrives, but that needs this process to have closed it, and a crash leaves it to the system.
final class ContainerProcesses: Sendable {
    static let shared = ContainerProcesses()

    private let live = Mutex<[ObjectIdentifier: RunnerHandle]>([:])

    var liveCount: Int { live.withLock { $0.count } }  // @dw:accept:this referenced-only-by-tests -- a test reads it

    func register(_ handle: RunnerHandle) {
        live.withLock { $0[ObjectIdentifier(handle)] = handle }
    }

    func unregister(_ handle: RunnerHandle) {
        live.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(handle)) }
    }

    /// Asks every live runner to stop, waits up to `timeout` for them to end, then kills the ones still running and waits up
    /// to `killWait` for the system to report it. Blocks the calling thread for at most `timeout + killWait`, and does not need
    /// the main actor, so the app can call it from `applicationWillTerminate`.
    func terminateAll(  // @dw:accept:this referenced-only-by-tests -- called at app quit
        timeout: Duration = .seconds(5), killWait: Duration = .seconds(1)
    ) {
        let handles = live.withLock { Array($0.values) }
        for handle in handles { handle.requestStop() }
        Self.wait(until: handles, within: timeout)
        for handle in handles { handle.forceKill() }
        Self.wait(until: handles, within: killWait)
    }

    private static func wait(until handles: [RunnerHandle], within limit: Duration) {
        let deadline = ContinuousClock.now + limit
        while handles.contains(where: \.isRunning), ContinuousClock.now < deadline {
            usleep(5000)
        }
    }
}
