import Foundation

/// The outcome of the baseline run, decided from what the container printed and its exit status.
public enum SpikeVerdict: Equatable, Sendable {
    case passed
    case commandFailed(exitCode: Int32)
    case unexpectedOutput

    /// What the container's `uname -a` must contain on an Apple silicon host.
    public static let expectedArchitecture = "aarch64"

    public static func evaluate(exitCode: Int32, output: String) -> Self {
        guard exitCode == 0 else { return .commandFailed(exitCode: exitCode) }
        return output.contains(expectedArchitecture) ? .passed : .unexpectedOutput
    }

    public var summary: String {
        switch self {
        case .passed: "passed"
        case .commandFailed(let exitCode): "failed: the command exited with status \(exitCode)"
        case .unexpectedOutput: "failed: the output does not contain \(Self.expectedArchitecture)"
        }
    }
}

/// Exit statuses of the `ContainerSpike` executable, in the `sysexits.h` style the repository's tooling uses.
public enum SpikeStatus {
    public static let passed: Int32 = 0
    /// The container ran and the result was wrong.
    public static let failed: Int32 = 1
    /// EX_USAGE.
    public static let usage: Int32 = 64
    /// EX_SOFTWARE: something before or around the container failed (download, checksum, pull, boot).
    public static let setupFailed: Int32 = 70
}

/// The lines the owner copies back from a run: what each phase cost, what the container printed, how it ended.
public struct SpikeReport: Equatable, Sendable {
    public struct Phase: Equatable, Sendable {
        public let name: String
        public let duration: Duration

        public init(name: String, duration: Duration) {
            self.name = name
            self.duration = duration
        }
    }

    /// How many frames the report lists; the count line says how many there were.
    private static let listedFrames = 20

    public var phases: [Phase] = []
    public var output = ""
    public var exitCode: Int32?
    public var verdict: SpikeVerdict?
    /// The frames the guest's network device delivered, and what they show. Both stay empty without a loopback network.
    public var frames: [FrameSummary] = []
    public var networkVerdict: NetworkVerdict?

    public init() {}

    /// The spike's own exit status: ``SpikeStatus/passed`` only when the run reached a verdict and every verdict passed;
    /// ``SpikeStatus/setupFailed`` when the run never reached one; ``SpikeStatus/failed`` otherwise.
    public var processStatus: Int32 {
        guard let verdict else { return SpikeStatus.setupFailed }
        return verdict == .passed && (networkVerdict ?? .passed) == .passed ? SpikeStatus.passed : SpikeStatus.failed
    }

    /// `duration` as seconds with two decimals, rounded half up. A negative duration reads as zero.
    public static func seconds(_ duration: Duration) -> String {
        let parts = duration.components
        let milliseconds = max(0, parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
        let hundredths = (milliseconds + 5) / 10
        let fraction = hundredths % 100
        return "\(hundredths / 100).\(fraction < 10 ? "0" : "")\(fraction)"
    }

    public var lines: [String] {
        var lines = phases.map { "\($0.name)-seconds: \(Self.seconds($0.duration))" }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("output: \(trimmed)")
        lines.append("exit-status: \(exitCode.map(String.init) ?? "none")")
        lines.append("verdict: \(verdict?.summary ?? "not reached")")
        if let networkVerdict {
            lines.append("frames-seen: \(frames.count)")
            lines += frames.prefix(Self.listedFrames).map { "frame: \($0)" }
            lines.append("network-verdict: \(networkVerdict.summary)")
        }
        return lines
    }
}
