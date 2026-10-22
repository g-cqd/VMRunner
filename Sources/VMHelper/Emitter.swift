import Foundation
import VMHelperCore

/// Writes the helper's events to standard output, one JSON line each, and keeps the clock they are stamped with.
///
/// Standard error belongs to the guest's serial console and to diagnostics, so a launcher can read events from
/// standard output without filtering.
struct Emitter: Sendable {
    private let start = ContinuousClock.now
    private let pid = ProcessInfo.processInfo.processIdentifier

    var elapsed: Double {
        let parts = (ContinuousClock.now - start).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    func emit(_ kind: HelperEvent.Kind, message: String? = nil, check: String? = nil, verdict: HelperEvent.Verdict? = nil) {
        let event = HelperEvent(kind, time: elapsed, pid: pid, message: message, check: check, verdict: verdict)
        guard let line = try? event.line() else { return }
        // One write per line, so lines from the helper never interleave mid-line.
        try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
    }
}
