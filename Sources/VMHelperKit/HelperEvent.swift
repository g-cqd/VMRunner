import Foundation

/// A line the helper writes to standard output: one JSON object per line, in the order things happened.
///
/// `time` is seconds on the monotonic clock since the helper started, so a boot time is the difference between two
/// events and does not depend on the launcher's clock.
public struct HelperEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// The configuration is built and validated; the machine is about to start.
        case booting
        /// The framework reports the machine running.
        case running
        /// The machine ended; `message` says why (`guest`, `time limit`).
        case stopped
        /// Something failed; `message` says what and the process exits with the matching status.
        case error
        /// `--dry-run` built and validated the configuration without starting it.
        case validated
        /// One result of `--probe`: `check` names the operation and `verdict` says whether the sandbox let it through.
        case probe
    }

    /// What the sandbox did with one probed operation.
    public enum Verdict: String, Codable, Sendable {
        /// The operation went through (it may still have failed afterwards, for a reason that has nothing to do with the sandbox).
        case allowed
        /// The sandbox refused it.
        case refused
        /// The probe could not tell, for instance because the file it was to open does not exist.
        case inconclusive

        public init(allowed: Bool) {
            self = allowed ? .allowed : .refused
        }
    }

    public var event: Kind
    public var time: Double
    public var pid: Int32
    public var message: String?
    public var check: String?
    public var verdict: Verdict?

    public init(
        _ event: Kind, time: Double, pid: Int32, message: String? = nil, check: String? = nil, verdict: Verdict? = nil
    ) {
        self.event = event
        self.time = time
        self.pid = pid
        self.message = message
        self.check = check
        self.verdict = verdict
    }

    /// The JSON object as one line, without the newline.
    public func line() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let line = String(bytes: try encoder.encode(self), encoding: .utf8) else {
            throw HelperFailure.virtualMachine("an event is not valid UTF-8")
        }
        return line
    }

    /// The events in `output`, in order. A line that is not an event (a stray diagnostic) is skipped.
    public static func parse(lines output: String) -> [Self] {
        output.split(whereSeparator: \.isNewline).compactMap { try? JSONDecoder().decode(Self.self, from: Data($0.utf8)) }
    }
}

/// Why the helper stops with a failure, and the exit status that says so (the `sysexits.h` values).
public enum HelperFailure: Error, Equatable, Sendable {
    case usage(String)
    case invalidDescriptor(String)
    case missingFile(String)
    case configurationRejected(String)
    case virtualMachine(String)

    public var exitStatus: Int32 {
        switch self {
        case .usage: 64
        case .invalidDescriptor: 65
        case .missingFile: 66
        case .configurationRejected: 69
        case .virtualMachine: 70
        }
    }

    public var message: String {
        switch self {
        case .usage(let text), .invalidDescriptor(let text), .missingFile(let text), .configurationRejected(let text),
            .virtualMachine(let text):
            text
        }
    }

    /// What each status means, for the help text and the launcher's report.
    public static func meaning(ofStatus status: Int32) -> String {
        switch status {
        case 0: "success: the machine stopped, or a dry run or a probe finished"
        case 64: "usage: bad command line"
        case 65: "the descriptor is unreadable or unacceptable"
        case 66: "a file the descriptor names does not exist"
        case 69: "the framework rejected the configuration, or virtualization is unavailable"
        case 70: "the machine failed to start or stopped with an error"
        case 134: "aborted by the system (a sandbox that denies what the loader needs does this)"
        default: "unexpected status \(status)"
        }
    }
}
