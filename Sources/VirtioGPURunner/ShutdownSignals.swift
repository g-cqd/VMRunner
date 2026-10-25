import Foundation

/// Turns the signals that ask the runner to end into calls on the main queue. No code runs in signal context: each signal is
/// ignored and received through a dispatch source instead (the kernel reports a signal to such a source even when it is
/// ignored), so the handler is ordinary main-queue code that may write files, log and end the run.
@MainActor
final class ShutdownSignals {
    private let signals: [Int32]
    private var sources: [any DispatchSourceSignal] = []

    /// Starts watching `signals`; `handler` runs on the main queue once for each signal that arrives.
    init(signals: [Int32] = [SIGTERM, SIGINT], handler: @escaping @MainActor (Int32) -> Void) {
        self.signals = signals
        for number in signals {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { handler(number) }
            }
            source.resume()
            sources.append(source)
        }
    }

    /// Stops watching and gives each signal its default action back.
    func stop() {
        for source in sources { source.cancel() }
        sources.removeAll()
        for number in signals { signal(number, SIG_DFL) }
    }
}
