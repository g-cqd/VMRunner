import Foundation

/// One kind of operation the sandbox refused, as the unified log reports it.
struct SandboxDenial: Equatable {
    let operation: String
    let target: String
    var count: Int
}

/// Reading a process's sandbox denials back from the unified log.
///
/// The kernel logs each refusal as `Sandbox: <name>(<pid>) deny(1) <operation> <target>`, with the sender `Sandbox`, and
/// summarises repeats of the same message as `N duplicate reports for Sandbox: ...`. `sandbox-exec` replaces itself with the
/// helper, so the pid of the launched process is the pid in the messages before and after. The log is written a moment
/// after the refusal, so the caller waits before it asks. Some refusals are never logged (a loader that cannot map the dyld
/// cache simply aborts), which is why the report also shows the exit status.
enum SandboxLog {
    /// `log show` arguments for the denials of `pid` in the last `seconds` seconds.
    static func arguments(pid: Int32, lastSeconds: Int) -> [String] {
        ["show", "--last", "\(max(lastSeconds, 1))s", "--style", "compact", "--predicate", predicate(pid: pid)]
    }

    static func predicate(pid: Int32) -> String {
        "sender == \"Sandbox\" AND eventMessage CONTAINS \"(\(pid)) deny\""
    }

    /// The denials in `output` that belong to `pid`, most frequent first.
    static func parse(_ output: String, pid: Int32) -> [SandboxDenial] {
        var counts: [String: SandboxDenial] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let match = line.firstMatch(of: #/Sandbox: [^(]+\((\d+)\) deny\(\d+\) (\S+)(?: (.+))?$/#),
                Int32(match.output.1) == pid
            else { continue }
            let operation = String(match.output.2)
            let target = match.output.3.map(String.init) ?? ""
            let repeats = line.firstMatch(of: #/(\d+) duplicate reports? for Sandbox:/#).flatMap { Int($0.output.1) }
            counts["\(operation) \(target)", default: SandboxDenial(operation: operation, target: target, count: 0)].count += repeats ?? 1
        }
        return counts.values.sorted { ($1.count, $0.operation, $0.target) < ($0.count, $1.operation, $1.target) }
    }
}
