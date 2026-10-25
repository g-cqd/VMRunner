import Foundation
import Testing

@testable import VirtioGPURunner

@MainActor
struct ShutdownSignalsTests {
    @Test(.timeLimit(.minutes(1)))
    func aSignalReachesTheHandlerOnTheMainThreadAndTheProcessSurvives() async {
        var watch: ShutdownSignals?
        let (number, onMainThread) = await withCheckedContinuation { (continuation: CheckedContinuation<(Int32, Bool), Never>) in
            watch = ShutdownSignals(signals: [SIGUSR1]) { continuation.resume(returning: ($0, Thread.isMainThread)) }
            // Sent to the process, as `kill` and a terminal's interrupt do; `raise` is aimed at a thread, which a source ignores.
            _ = kill(getpid(), SIGUSR1)
        }
        watch?.stop()
        #expect(number == SIGUSR1)
        #expect(onMainThread, "the handler is ordinary main-queue code, not a signal handler")
    }
}
