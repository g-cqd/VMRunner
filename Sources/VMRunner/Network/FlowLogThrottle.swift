import Foundation

/// Turns flow events into log lines, at most one per destination and reason per ``interval``.
///
/// The guest decides how many denials and failures there are, and every one of them used to be a line in the system
/// log. A line that went out says how many like it were held back since the last one; the rest are only counted. The
/// table of destinations is bounded, so a guest that sweeps ports gets ``capacity`` lines per interval, not a line per
/// probe. Time is the event's own, from the stack's clock.
struct FlowLogThrottle {
    /// One log line: the public parts (kind, outcome, reason) and the private destination, kept apart so the caller
    /// can mark each with its own privacy.
    struct Line: Equatable {
        let kind: String
        let outcome: String
        let reason: String
        let destination: String
        /// Events like this one that were held back since the previous line for the same destination and reason.
        let held: Int

        /// The public part of the line: `tcp denied (policy)`.
        var summary: String { "\(kind) \(outcome) (\(reason))" }
    }

    private struct Key: Hashable {
        let transport: FlowTransport
        let address: IPAddress
        let port: UInt16
        let outcome: String
        let reason: String
    }

    private struct Window {
        var until: TimeInterval
        var held: Int
    }

    static let interval: TimeInterval = 5
    static let capacity = 256

    private var windows: [Key: Window] = [:]

    /// The line for `event`, or `nil` when it is not worth one (an ordinary flow event) or an equal line went out
    /// within the interval.
    mutating func line(for event: FlowEvent) -> Line? {
        let outcome: String
        let reason: String
        switch event.phase {
        case .denied(let denial):
            outcome = "denied"
            reason = denial.logName
        case .closed(let closeReason) where closeReason.isFailure:
            outcome = "failed"
            reason = closeReason.logName
        case .closed, .opened, .answered:
            return nil
        }
        let key = Key(
            transport: event.transport, address: event.destinationAddress, port: event.destinationPort, outcome: outcome, reason: reason)
        let now = event.time
        var held = 0
        if var window = windows[key] {
            if now < window.until {
                window.held += max(event.count, 1)
                windows[key] = window
                return nil
            }
            held = window.held
        } else {
            if windows.count >= Self.capacity { dropExpired(now: now) }
            guard windows.count < Self.capacity else { return nil }
        }
        windows[key] = Window(until: now + Self.interval, held: 0)
        let destination = "\(event.destinationAddress.description):\(event.destinationPort) \(event.destinationName ?? "-")"
        return Line(kind: event.transport.rawValue, outcome: outcome, reason: reason, destination: destination, held: held)
    }

    private mutating func dropExpired(now: TimeInterval) {
        for (key, window) in windows where now >= window.until { windows[key] = nil }
    }
}
