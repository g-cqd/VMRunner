import Foundation

/// How the input latency monitor was asked for. It is off unless the launch arguments or the environment turn it on.
///
/// | Argument | Environment | Meaning |
/// |---|---|---|
/// | `--input-latency` | `VMR_INPUT_LATENCY` (anything but empty, `0`, `false`, `no`) | turn the monitor on |
/// | `--input-latency-threshold-ms N` | `VMR_INPUT_LATENCY_THRESHOLD_MS` | what counts as a stall or a late event, default 1 |
/// | `--input-latency-interval N` | `VMR_INPUT_LATENCY_INTERVAL` | seconds between summaries, default 10 |
/// | `--input-latency-file PATH` | `VMR_INPUT_LATENCY_FILE` | also append each summary to this file (absolute or `~/`) |
///
/// An argument beats the environment. A value that is missing or unusable is ignored with a warning and the default stands.
struct InputLatencyOptions: Equatable, Sendable {
    static let flag = "--input-latency"
    static let thresholdFlag = "--input-latency-threshold-ms"
    static let intervalFlag = "--input-latency-interval"
    static let fileFlag = "--input-latency-file"

    static let defaultThreshold: UInt64 = 1_000_000
    static let defaultInterval = 10
    static let thresholdMilliseconds = 0.001...1_000.0
    static let intervalSeconds = 1...3_600

    /// What counts as a stall or a late event, in nanoseconds.
    var threshold = defaultThreshold
    var interval = defaultInterval
    var file: URL?

    struct Parsed: Equatable, Sendable {
        /// `nil` when the monitor was not asked for.
        var options: InputLatencyOptions?
        /// What was wrong with the values, for the log. Never contains a path.
        var warnings: [String] = []
    }

    static func parse(arguments: [String], environment: [String: String]) -> Parsed {
        guard isOn(arguments: arguments, environment: environment) else { return Parsed(options: nil) }
        var parsed = Parsed(options: Self())

        func value(_ flag: String, _ variable: String) -> String? {
            if let index = arguments.firstIndex(of: flag) {
                guard arguments.indices.contains(index + 1) else {
                    parsed.warnings.append("\(flag) needs a value")
                    return nil
                }
                return arguments[index + 1]
            }
            return environment[variable].flatMap { $0.isEmpty ? nil : $0 }
        }

        if let text = value(thresholdFlag, "VMR_INPUT_LATENCY_THRESHOLD_MS") {
            if let milliseconds = Double(text), thresholdMilliseconds.contains(milliseconds) {
                parsed.options?.threshold = UInt64((milliseconds * 1_000_000).rounded())
            } else {
                parsed.warnings.append("the threshold must be a number of milliseconds from 0.001 to 1000")
            }
        }
        if let text = value(intervalFlag, "VMR_INPUT_LATENCY_INTERVAL") {
            if let seconds = Int(text), intervalSeconds.contains(seconds) {
                parsed.options?.interval = seconds
            } else {
                parsed.warnings.append("the interval must be a whole number of seconds from 1 to 3600")
            }
        }
        if let text = value(fileFlag, "VMR_INPUT_LATENCY_FILE") {
            let path = (text as NSString).expandingTildeInPath
            if path.hasPrefix("/"), !text.hasSuffix("/") {
                parsed.options?.file = URL(filePath: path)
            } else {
                parsed.warnings.append("the file must be an absolute path or start with ~/")
            }
        }
        return parsed
    }

    private static func isOn(arguments: [String], environment: [String: String]) -> Bool {
        if arguments.contains(flag) { return true }
        guard let text = environment["VMR_INPUT_LATENCY"]?.lowercased() else { return false }
        return !["", "0", "false", "no"].contains(text)
    }
}
