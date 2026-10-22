import Foundation
import NetPolicy
import NetStack

/// One line of the recent-connections log: what the guest tried to reach and what the policy decided.
struct FlowLogEntry: Identifiable, Hashable, Sendable {
    enum Outcome: Hashable, Sendable {
        case allowed, denied
    }

    /// Increases with arrival order within one machine run.
    let id: Int
    let outcome: Outcome
    let transport: FlowTransport
    /// The name the guest asked for or was given, with the address and port, such as `example.com (93.184.216.34:443)`.
    let destination: String
    /// Why: the matching rule for a denial, or the plain outcome for an allowed connection.
    let detail: String
    /// How many attempts the line stands for: more than one when identical refusals were folded together ("x 40").
    let count: Int

    /// How many attempts an event stands for: more than one when identical refusals were folded together.
    static func attempts(of event: FlowEvent) -> Int { max(event.count, 1) }

    /// What the log says about a phase, or `nil` when it has no line. Decided without building the line, so a flood of events
    /// can be counted cheaply.
    static func outcome(of phase: FlowEvent.Phase) -> Outcome? {
        switch phase {
        case .opened, .answered: .allowed
        case .denied, .closed(.policyRevoked): .denied
        case .closed: nil
        }
    }

    /// The log line for `event`, or `nil` for events that are not worth a line (a connection ending normally).
    init?(event: FlowEvent, id: Int) {
        self.id = id
        transport = event.transport
        destination = event.destinationText
        count = Self.attempts(of: event)
        switch event.phase {
        case .opened:
            outcome = .allowed
            detail = "Allowed"
        case .denied(let denial):
            outcome = .denied
            detail = count > 1 ? "\(denial.explanation) × \(count)" : denial.explanation
        case .answered(let code):
            outcome = .allowed
            detail = FlowEvent.answerText(responseCode: code)
        case .closed(.policyRevoked(let reason)):
            outcome = .denied
            detail = "Closed after a policy change: \(reason.explanation)"
        case .closed:
            return nil
        }
    }
}

/// The host's and the guest's VPN signals side by side, with the wording and symbol to show for them.
///
/// Both are heuristics. The host signal says a tunnel interface is up on the Mac; the guest signal says the traffic
/// leaving the guest looks like a VPN handshake. Neither proves where a particular packet goes.
struct VPNIndicator: Equatable, Sendable {
    enum Level: Sendable {
        /// Nothing to report.
        case quiet
        /// The Mac has a VPN up.
        case hostVPN
        /// The guest seems to run its own VPN, which the filter cannot see into.
        case guestVPN
    }

    let host: VPNState
    let guest: GuestVPNState

    var level: Level {
        if guest.kind != nil { .guestVPN } else if host == .active { .hostVPN } else { .quiet }
    }

    var hostText: String {
        switch host {
        case .active: "Mac VPN: active"
        case .inactive: "Mac VPN: not detected"
        case .unknown: "Mac VPN: unknown"
        }
    }

    var guestText: String { guest.eventLine }

    /// What the detector saw, strongest first, at most three lines.
    var guestEvidence: [String] {
        guard case .suspected(_, _, _, let evidence) = guest else { return [] }
        return evidence.prefix(3).map(\.reason)
    }

    var symbol: String {
        switch level {
        case .quiet: "network.badge.shield.half.filled"
        case .hostVPN: "lock.shield"
        case .guestVPN: "exclamationmark.shield"
        }
    }
}
