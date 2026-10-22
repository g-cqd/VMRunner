import Foundation
import VMHelperCore

/// One launch of the helper under an engine, with what was seen of it.
struct SandboxPhase {
    enum Mode: String {
        case probe
        case dryRun = "dry-run"
        case start

        /// The helper's command-line flag for this mode.
        var flag: String { "--" + rawValue }
    }

    /// What the guest's serial console showed during a `start` phase.
    struct Console: Equatable {
        var lines: Int
        /// Seconds from the `booting` event (as the launcher saw it) to the first console line, if one came.
        var firstLineAfterBooting: Double?
    }

    let mode: Mode
    /// The helper's exit status, or 128 plus the signal number.
    let status: Int32
    let timedOut: Bool
    let events: [HelperEvent]
    let console: Console?
    /// `nil` when the helper reported no pid (it never got far enough), so the log could not be asked.
    let denials: [SandboxDenial]?
    /// Wall-clock seconds the launch took, as the launcher measured it.
    let seconds: Double

    var probeResults: [HelperEvent] { events.filter { $0.event == .probe } }

    func event(_ kind: HelperEvent.Kind) -> HelperEvent? { events.first { $0.event == kind } }

    func verdict(of check: String) -> HelperEvent.Verdict? { probeResults.first { $0.check == check }?.verdict }
}

/// The plain-text report of a sandbox run.
enum SandboxReport {
    static let denialLimit = 25

    static func lines(engine: SandboxEngine, level: SandboxLevel, descriptorPath: String, helperPath: String, phases: [SandboxPhase])
        -> [String]
    {
        var lines = [
            "sandbox helper report",
            "  engine:     \(engine.rawValue)",
            "  level:      \(level.rawValue)",
            "  descriptor: \(descriptorPath)",
            "  helper:     \(helperPath)",
            "",
        ]
        let probe = phases.first { $0.mode == .probe }
        let dryRun = phases.first { $0.mode == .dryRun }
        let start = phases.first { $0.mode == .start }
        lines += [
            "boots at all:         \(boots(start))",
            "boot time:            \(bootTime(start))",
            "dry run:              \(validates(dryRun))",
            "user-mode networking: \(networking(probe))",
            "name resolution:      \(resolution(probe))",
            "sandbox denials:      \(denialTotal(phases))",
        ]
        for phase in phases {
            lines += ["", detail(of: phase)]
            lines += refused(in: phase)
            lines += denials(of: phase)
        }
        lines += [
            "",
            "note: the kernel throttles its sandbox log lines, so the log counts are a lower bound (three identical runs in a row",
            "logged 0, 0 and 1 of the same three denials). The `refused` lines are what the probe itself saw refused, log or no log.",
        ]
        return lines
    }

    // MARK: Summary lines

    static func boots(_ start: SandboxPhase?) -> String {
        guard let start else { return "not run (starting a virtual machine needs --boot, which only the owner passes)" }
        if let running = start.event(.running) { return "yes: the framework reported the machine running after \(seconds(running.time))" }
        return "no: \(failure(of: start))"
    }

    static func bootTime(_ start: SandboxPhase?) -> String {
        guard let start, let running = start.event(.running) else { return "not measured" }
        var text = "\(seconds(running.time - (start.event(.booting)?.time ?? 0))) from booting to running"
        text += " (\(seconds(running.time)) from the helper's start)"
        if let console = start.console {
            if let first = console.firstLineAfterBooting {
                text += "; the guest's first console line came \(seconds(first)) after booting (\(console.lines) lines)"
            } else {
                text += "; the guest wrote nothing to its console"
            }
        }
        return text
    }

    static func validates(_ dryRun: SandboxPhase?) -> String {
        guard let dryRun else { return "not run" }
        if dryRun.event(.validated) != nil { return "the configuration validated" }
        return "failed: \(failure(of: dryRun))"
    }

    static func networking(_ probe: SandboxPhase?) -> String {
        guard let probe, !probe.probeResults.isEmpty else { return "not probed" }
        let refused = ProbeCheck.userModeStack.filter { probe.verdict(of: $0) != .allowed }
        if refused.isEmpty { return "works: a socket pair, and TCP, UDP and ICMP echo sockets all went through" }
        return "refused: \(refused.joined(separator: "; "))"
    }

    static func resolution(_ probe: SandboxPhase?) -> String {
        guard let probe, !probe.probeResults.isEmpty else { return "not probed" }
        let check = ProbeCheck.resolve(ProbeCheck.remoteHost)
        guard let result = probe.probeResults.first(where: { $0.check == check }) else { return "not probed" }
        return result.verdict == .allowed
            ? "works (\(ProbeCheck.remoteHost) resolved)"
            : "fails (\(ProbeCheck.remoteHost): \(result.message ?? "no message")); compare with --engine none, which has no sandbox"
    }

    static func denialTotal(_ phases: [SandboxPhase]) -> String {
        let known = phases.compactMap(\.denials)
        guard !known.isEmpty else { return "not collected" }
        let total = known.joined().reduce(0) { $0 + $1.count }
        return total == 0 ? "none logged" : "\(total) logged (details below)"
    }

    // MARK: Per-phase detail

    static func detail(of phase: SandboxPhase) -> String {
        let meaning = HelperFailure.meaning(ofStatus: phase.status)
        var text = "\(phase.mode.rawValue): exit status \(phase.status) (\(meaning)), \(seconds(phase.seconds))"
        if phase.timedOut { text += ", killed at the launcher's time limit" }
        return text
    }

    /// The probe's refused and inconclusive operations: what the sandbox denied, as the helper itself saw it.
    static func refused(in phase: SandboxPhase) -> [String] {
        phase.probeResults.filter { $0.verdict != .allowed }.map {
            "  \($0.verdict == .refused ? "refused" : "unknown"):  \($0.check ?? "?") (\($0.message ?? ""))"
        }
    }

    static func denials(of phase: SandboxPhase) -> [String] {
        guard let denials = phase.denials else { return ["  log: not collected (the helper reported no pid, or `log show` failed)"] }
        guard !denials.isEmpty else { return ["  log: no sandbox denial logged"] }
        var lines = denials.prefix(denialLimit).map { "  log: \($0.count)x \($0.operation) \($0.target)" }
        if denials.count > denialLimit { lines.append("  log: and \(denials.count - denialLimit) more kinds of denial") }
        return lines
    }

    private static func failure(of phase: SandboxPhase) -> String {
        if let error = phase.event(.error)?.message { return error }
        if phase.timedOut { return "the helper did not finish before the launcher's time limit" }
        return "no error event; \(HelperFailure.meaning(ofStatus: phase.status))"
    }

    static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(3)).grouping(.never).locale(Locale(identifier: "en_US_POSIX"))) + " s"
    }
}
