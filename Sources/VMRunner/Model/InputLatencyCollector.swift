/// Keeps the input latency statistics and reports them at a steady pace. It reads no clock and touches no AppKit: the
/// monitor feeds it event ages and run-loop callbacks, and the reporting loop sleeps on the injected clock.
@MainActor
final class InputLatencyCollector {
    private var recorder: InputLatencyRecorder
    private let report: @MainActor (String) -> Void
    private var reporting: Task<Void, Never>?

    /// - Parameters:
    ///   - threshold: What counts as a stall or a late event, in nanoseconds.
    ///   - report: Receives each periodic summary line.
    init(threshold: UInt64, report: @escaping @MainActor (String) -> Void) {
        recorder = InputLatencyRecorder(threshold: threshold)
        self.report = report
    }

    isolated deinit { reporting?.cancel() }

    func recordEvent(_ kind: InputKind, age: UInt64) { recorder.recordEvent(kind, age: age) }
    func loopWoke(at now: UInt64) { recorder.loopWoke(at: now) }
    func loopWillLookAtSources(at now: UInt64) { recorder.loopWillLookAtSources(at: now) }
    @discardableResult
    func loopWillSleep(at now: UInt64) -> LoopStall? { recorder.loopWillSleep(at: now) }
    func workBegan(_ name: String, at now: UInt64) { recorder.workBegan(name, at: now) }
    func workEnded(at now: UInt64) { recorder.workEnded(at: now) }

    /// Reports the statistics of the time since the last report, every `interval` on `clock`, until ``stopReporting()``.
    func startReporting<C: Clock>(every interval: Duration, clock: C) where C.Duration == Duration {
        reporting?.cancel()
        reporting = Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: interval) } catch { return }
                guard let self else { return }
                report(recorder.rollWindow().summaryLine(label: "last \(interval)"))
            }
        }
    }

    func stopReporting() {
        reporting?.cancel()
        reporting = nil
    }

    /// The statistics of the whole run in one line.
    func totalLine() -> String { recorder.total.summaryLine(label: "total") }
}
