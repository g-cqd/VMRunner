import Foundation

/// `vmr container-run`: signs the runner (``ContainerSigner``), makes its scratch directory, runs it with the plan's options and
/// returns its exit status. Running it boots a virtual machine.
///
/// The runner writes to this process's standard output and error directly. SIGINT and SIGTERM end it: the runner is stopped
/// (SIGTERM, then SIGKILL after five seconds) before this process exits, so it is never left running, and the status is
/// 128 plus the signal's number.
struct ContainerRun {
    /// The status when the run-time limit stopped the runner, as for `vmr guest exec`.
    static let timedOutStatus: Int32 = 124

    let root: URL
    /// A runner that is built already, signed here instead of building one.
    let binary: URL?
    let configuration: AppBundler.Configuration
    let plan: ContainerRunPlan

    private enum Outcome: Sendable {
        case finished(CommandResult)
        case signalled(Int32)
    }

    func run() async throws -> Int32 {
        let runner = try await ContainerSigner(
            root: root, binary: binary, configuration: configuration, report: { Output.err($0) }
        ).run()
        try GuestScratch.ensurePrivate(plan.scratch)
        Output.err("scratch: \(plan.scratch.path)\(plan.isFresh ? " (new; delete it when you are done)" : "")")

        var spec = CommandSpec(executable: runner.path, arguments: plan.runnerArguments)
        // The runner reads standard input only with --json, where the end of input stops the container.
        spec.inheritsInput = plan.options.json
        spec.timeout = .seconds(plan.options.maximumSeconds)
        return try await launch(spec)
    }

    private func launch(_ spec: CommandSpec) async throws -> Int32 {
        let (signals, delivered) = AsyncStream.makeStream(of: Int32.self)
        // Watching starts before the runner does, so that no signal finds it unwatched.
        let relay = SignalRelay(signals: [SIGINT, SIGTERM]) { delivered.yield($0) }
        defer { relay.stop() }
        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do {
                    return .finished(try await ProcessRunner.run(spec, output: .inherit))
                } catch is CancellationError {
                    // Only a signal cancels the group, and its own task reports the number.
                    return .signalled(0)
                }
            }
            group.addTask {
                for await number in signals { return .signalled(number) }
                return .signalled(0)
            }
            var status: Int32 = 1
            var caught: Int32?
            // A signal cancels the group, which stops the runner; the runner's end cancels the wait for a signal.
            for try await outcome in group {
                switch outcome {
                case .finished(let result):
                    status = result.timedOut ? Self.timedOutStatus : result.status
                    if result.timedOut { Output.err("stopped: the run reached --max-seconds \(plan.options.maximumSeconds)") }
                case .signalled(let number):
                    caught = caught ?? (number == 0 ? nil : number)
                }
                group.cancelAll()
            }
            return caught.map { 128 + $0 } ?? status
        }
    }
}

/// Reports SIGINT and SIGTERM (or any signals) to a handler while it is active, in place of ending this process; ``stop()``
/// gives each signal its default action back. Each signal is set to be ignored and is received through a dispatch source,
/// so no code runs in signal context.
final class SignalRelay {
    private let signals: [Int32]
    private var sources: [any DispatchSourceSignal] = []

    init(signals: [Int32], handler: @escaping @Sendable (Int32) -> Void) {
        self.signals = signals
        for number in signals {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number)
            source.setEventHandler { handler(number) }
            source.resume()
            sources.append(source)
        }
    }

    deinit {
        stop()
    }

    /// Cancels the sources and restores the default actions. Calling it again does nothing.
    func stop() {
        guard !sources.isEmpty else { return }
        for source in sources { source.cancel() }
        sources.removeAll()
        for number in signals { signal(number, SIG_DFL) }
    }
}
