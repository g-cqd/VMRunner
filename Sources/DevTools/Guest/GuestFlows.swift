import Foundation
import VMHelperCore

/// `vmr guest flows`: what a filtered guest's connections did, from the helper's log.
struct GuestFlows {
    let scratch: GuestScratch
    /// How many of the newest flow lines to show.
    var last = 50
    /// Only lines with this outcome (`allowed`, `denied`, `answered`, `closed`, `revoked`).
    var outcome: String?

    /// The lines to print: the flow events and the guest-VPN verdicts (oldest first, the newest `last` of them), then the latest
    /// counters.
    func lines() throws -> [String] {
        let events = GuestLogReader(file: scratch.logFile).allEvents
        guard !events.isEmpty else { throw ToolError("\(scratch.logFile.path) holds no events; is a guest running from here?") }
        // The guest-VPN verdicts are not flows, so they show only when no outcome narrows the list.
        let flows = events.filter { ($0.event == .flow && (outcome == nil || $0.check == outcome)) || ($0.event == .vpn && outcome == nil) }
        var lines = flows.suffix(max(last, 0)).map { Self.line(for: $0) }
        if lines.isEmpty { lines.append("no flow events" + (outcome.map { " with the outcome \($0)" } ?? "")) }
        if let counters = events.last(where: { $0.event == .statistics }) {
            lines.append("counters: \(counters.message ?? "")")
        }
        return lines
    }

    /// `[ 12.345] TCP denied example.com (93.184.216.34:80): ...`, the time being seconds since the helper started.
    static func line(for event: HelperEvent) -> String {
        let seconds = event.time.formatted(.number.precision(.fractionLength(3)).locale(Locale(identifier: "en_US_POSIX")))
        return "[\(String(repeating: " ", count: max(0, 9 - seconds.count)))\(seconds)] \(event.message ?? "")"
    }
}
