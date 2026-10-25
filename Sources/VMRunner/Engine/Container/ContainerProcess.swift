import Foundation

/// How a runner process ended.
struct ContainerExit: Equatable, Sendable {
    /// The exit status, or the signal number when `signaled`.
    let status: Int32
    let signaled: Bool

    /// What `waitForExit()` returns for a process that was never started: no runner ran, so there is no status.
    static let notStarted = Self(status: -1, signaled: false)  // @dw:accept:this referenced-only-by-tests -- waitForExit returns it
}

/// Why a runner did not start.
struct ContainerProcessError: LocalizedError, Equatable {
    let reason: String
    var errorDescription: String? { reason }
}

/// Runs one container runner as a child process and follows it: its event lines go into a ``ContainerLog`` in order, its
/// standard error becomes the log's diagnostics, and the process's end is reported once, after the last of its output.
///
/// Stopping is a request first: `stop()` writes `stop` to the runner's standard input and closes it; a runner still alive after
/// `Timing.stopGrace` gets SIGTERM, and after `Timing.terminateGrace` more SIGKILL. `kill()` is SIGKILL at once. The waits use
/// the injected clock. The process is in ``ContainerProcesses`` while it runs, and every descriptor this class opened is
/// closed when the run ends. The scratch folder is not touched: it holds the downloaded kernel and image cache.
///
/// The output is read off the main actor, by dispatch sources on descriptors this class owns, and queued for the main actor
/// with a byte budget: readers pause above 4 MiB queued and go on below 1 MiB. A process released while its runner still runs
/// kills the runner and closes everything.
@MainActor
final class ContainerProcess {
    struct Timing: Sendable {
        /// How long a requested stop may take before SIGTERM.
        var stopGrace = Duration.seconds(10)
        /// How long SIGTERM may take before SIGKILL.
        var terminateGrace = Duration.seconds(5)
        /// How long the output may take to end after the process did, before it is given up (a descendant that kept the
        /// pipe open would hold it forever).
        var drainGrace = Duration.seconds(2)
    }

    /// How many times the drain wait starts again while output that was read is still waiting to be applied.
    private static let maxDrainRearms = 5

    private enum Input: Sendable {
        case stdout([UInt8])
        case stderr([UInt8])
        case stdoutEnded, stderrEnded
        case readerClosed
        case terminated(ContainerExit)
        case drainExpired

        /// The bytes this report counts in the backlog.
        var byteCount: Int {
            switch self {
            case .stdout(let bytes), .stderr(let bytes): bytes.count
            default: 0
            }
        }
    }

    let log: ContainerLog
    /// Set once, when the run ended and all its output was applied to the log.
    private(set) var exit: ContainerExit?
    /// Called for each event the runner reported, in order, after the log has it.
    var onEvent: (@MainActor (ContainerEvent) -> Void)?
    /// Called once with the exit, on the main actor, after the log has everything.
    var onExit: (@MainActor (ContainerExit) -> Void)?

    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let clock: any Clock<Duration>
    private let timing: Timing
    private let registry: ContainerProcesses
    private let backlog: OutputBacklog
    private let ledger = DescriptorLedger()

    private var handle: RunnerHandle?
    private var readers: [PipeReader] = []
    private var continuation: AsyncStream<Input>.Continuation?
    /// The timers: the stop escalation and the drain wait.
    private var tasks: [Task<Void, Never>] = []
    private var stopRequested = false
    private var splitter = RunnerLineSplitter()
    private var stdoutEnded = false
    private var stderrEnded = false
    private var closedReaders = 0
    private var drainRearms = 0
    private var terminated: ContainerExit?
    /// Set when the output is over: the readers were told to stop, and the run is reported once they closed their descriptors.
    private var closing: ContainerExit?
    private var waiters: [CheckedContinuation<ContainerExit, Never>] = []

    init(
        executable: URL, arguments: [String],
        environment: [String: String] = ContainerRunnerArguments.minimalEnvironment(from: ProcessInfo.processInfo.environment),
        log: ContainerLog = ContainerLog(), clock: any Clock<Duration> = ContinuousClock(), timing: Timing = Timing(),
        registry: ContainerProcesses = .shared, backlog: OutputBacklog = OutputBacklog()
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.log = log
        self.clock = clock
        self.timing = timing
        self.registry = registry
        self.backlog = backlog
    }

    isolated deinit {
        guard let handle, exit == nil else { return }
        handle.forceKill()
        backlog.close()
        for reader in readers { reader.cancel() }
        handle.closeStdin()
        registry.unregister(handle)
        continuation?.finish()
        for task in tasks { task.cancel() }
    }

    var isRunning: Bool { handle != nil && exit == nil }

    /// The descriptors this run holds open: none before the start and after the end.
    var openDescriptorCount: Int { ledger.count }  // @dw:accept:this referenced-only-by-tests -- a test reads it

    /// Starts the runner. Throws when the file is not an executable or the system refuses to start it; nothing stays open then.
    func start() throws {
        guard handle == nil, exit == nil else { throw ContainerProcessError(reason: "The container runner was already started.") }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ContainerProcessError(reason: "The container runner is missing or not executable: \(executable.path)")
        }
        guard let pipes = RunnerPipes(ledger: ledger) else {
            throw ContainerProcessError(reason: "The container runner's pipes could not be opened.")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        pipes.connect(process)
        guard let handle = RunnerHandle(process: process, stdin: pipes.input, ledger: ledger) else {
            pipes.closeChildEnds()
            pipes.closeReadEnds()
            pipes.closeInput()
            throw ContainerProcessError(reason: "The container runner's input could not be prepared.")
        }
        let (stream, continuation) = AsyncStream.makeStream(of: Input.self)
        process.terminationHandler = { process in
            let signaled = process.terminationReason == .uncaughtSignal
            continuation.yield(.terminated(ContainerExit(status: process.terminationStatus, signaled: signaled)))
        }
        do {
            try process.run()
        } catch {
            pipes.closeChildEnds()
            pipes.closeReadEnds()
            handle.closeStdin()
            continuation.finish()
            throw ContainerProcessError(reason: "The container runner did not start: \(error.localizedDescription)")
        }
        // The child has its own copies of its ends; the parent's copies would keep the pipes open after the child is gone.
        pipes.closeChildEnds()
        readers = [
            follow(pipes.outputRead, into: continuation, data: Input.stdout, ended: .stdoutEnded),
            follow(pipes.errorRead, into: continuation, data: Input.stderr, ended: .stderrEnded),
        ]
        self.handle = handle
        self.continuation = continuation
        registry.register(handle)
        Task { [weak self] in
            for await input in stream {
                guard let self else { return }
                if self.apply(input) { return }
            }
        }
    }

    /// Asks the runner to stop and escalates when it does not: SIGTERM after the grace, SIGKILL after another. Does nothing
    /// when the run is not started, ended, or already asked to stop.
    func stop() {
        guard let handle, exit == nil, !stopRequested else { return }
        stopRequested = true
        handle.requestStop()
        tasks.append(
            Task { [clock, timing] in
                guard (try? await clock.sleep(for: timing.stopGrace)) != nil else { return }
                handle.terminate()
                guard (try? await clock.sleep(for: timing.terminateGrace)) != nil else { return }
                handle.forceKill()
            })
    }

    /// SIGKILL at once. Does nothing when the run is not started or ended.
    func kill() {
        guard exit == nil else { return }
        handle?.forceKill()
    }

    /// Returns the exit, waiting for the run to end when it has not. A process that was never started has no run to wait for: it
    /// returns ``ContainerExit/notStarted`` at once.
    func waitForExit() async -> ContainerExit {  // @dw:accept:this referenced-only-by-tests -- the machine start awaits the end with it
        if let exit { return exit }
        guard handle != nil else { return .notStarted }
        return await withCheckedContinuation { waiters.append($0) }
    }

    // MARK: - Following the process

    /// Follows the read end `descriptor`, which the reader owns from now on, and reports each piece, then its end, then the
    /// closing of the descriptor, in order.
    private nonisolated func follow(
        _ descriptor: Int32, into continuation: AsyncStream<Input>.Continuation, data: @escaping @Sendable ([UInt8]) -> Input,
        ended: Input
    ) -> PipeReader {
        PipeReader.follow(descriptor, backlog: backlog, ledger: ledger) { report in
            switch report {
            case .data(let bytes): continuation.yield(data(bytes))
            case .ended: continuation.yield(ended)
            case .closed: continuation.yield(.readerClosed)
            }
        }
    }

    /// Applies one report; true when the run is over and nothing more is read.
    private func apply(_ input: Input) -> Bool {
        defer { backlog.applied(input.byteCount) }
        if case .readerClosed = input { closedReaders += 1 }
        if let closing {
            // The output is over: what still arrives is dropped, and the run is reported when the last reader closed.
            return reportIfClosed(closing)
        }
        var drainExpired = false
        switch input {
        case .stdout(let bytes):
            for line in splitter.append(bytes) { applyLine(line) }
            log.noteDroppedLines(total: splitter.droppedLines)
        case .stderr(let bytes):
            log.appendDiagnostics(bytes)
        case .stdoutEnded:
            stdoutEnded = true
        case .stderrEnded:
            stderrEnded = true
        case .readerClosed:
            break
        case .terminated(let exit):
            terminated = exit
            if !(stdoutEnded && stderrEnded) { armDrainTimer() }
        case .drainExpired:
            guard !rearmDrainTimer() else { return false }
            drainExpired = true
        }
        guard let terminated, (stdoutEnded && stderrEnded) || drainExpired else { return false }
        beginClosing(with: terminated)
        return reportIfClosed(terminated)
    }

    private func applyLine(_ line: [UInt8]) {
        guard let event = ContainerEvent(line: line) else { return log.noteIgnoredLine() }
        log.apply(event)
        onEvent?(event)
    }

    /// Waits for the output to end, after the process did, for `Timing.drainGrace`.
    private func armDrainTimer() {
        tasks.append(
            Task { [clock, timing, continuation] in
                guard (try? await clock.sleep(for: timing.drainGrace)) != nil else { return }
                continuation?.yield(.drainExpired)
            })
    }

    /// True when the drain wait ran out while read output was still waiting to be applied: the application is behind, not the
    /// runner's descendants holding the pipe, so the wait starts again. It does so a few times at most.
    private func rearmDrainTimer() -> Bool {
        guard backlog.queuedBytes > 0, drainRearms < Self.maxDrainRearms else { return false }
        drainRearms += 1
        armDrainTimer()
        return true
    }

    /// Ends the reading: the last partial line, the timers, the input, the registry, and the readers, which close their
    /// descriptors on their own queues.
    private func beginClosing(with result: ContainerExit) {
        for line in splitter.finish() { applyLine(line) }
        log.noteDroppedLines(total: splitter.droppedLines)
        closing = result
        for task in tasks { task.cancel() }
        tasks = []
        if let handle {
            handle.closeStdin()
            registry.unregister(handle)
        }
        backlog.close()
        for reader in readers { reader.cancel() }
    }

    /// Reports the run once every reader has closed its descriptor; true when it did.
    private func reportIfClosed(_ result: ContainerExit) -> Bool {
        guard closedReaders == readers.count else { return false }
        continuation?.finish()
        continuation = nil
        exit = result
        onExit?(result)
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume(returning: result) }
        return true
    }
}
