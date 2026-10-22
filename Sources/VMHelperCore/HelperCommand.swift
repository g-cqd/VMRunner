/// A command line the launcher writes to a running helper's standard input (`--commands`), one per line.
///
///     policy [keep|terminate]   read the descriptor's network policy file again and apply it; open flows that the new policy
///                               no longer allows are cut (`terminate`, the default) or left alone (`keep`)
///     statistics                report the stack's counters now
///
/// The helper answers a `policy` command with a `policy` event and a `statistics` command with a `statistics` event. A line it
/// cannot read is answered with a `policy` event whose check is `rejected`, and the machine goes on.
public enum HelperCommand: Equatable, Sendable {
    case reloadPolicy(terminatingOpenFlows: Bool)
    case statistics

    /// Why a line is not a command, in words for the event that reports it.
    public struct Unreadable: Error, Equatable, Sendable {
        public let reason: String
    }

    /// The command in `line`; a blank line is not a command (`nil`).
    public static func parse(_ line: String) throws(Unreadable) -> Self? {
        let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let name = words.first else { return nil }
        let arguments = Array(words.dropFirst())
        switch (name, arguments) {
        case ("policy", []), ("policy", ["terminate"]): return .reloadPolicy(terminatingOpenFlows: true)
        case ("policy", ["keep"]): return .reloadPolicy(terminatingOpenFlows: false)
        case ("statistics", []): return .statistics
        case ("policy", _): throw Unreadable(reason: "policy takes keep or terminate, not \(arguments.joined(separator: " "))")
        case ("statistics", _): throw Unreadable(reason: "statistics takes no argument")
        default: throw Unreadable(reason: "unknown command '\(name)'; the commands are policy and statistics")
        }
    }

    /// The line that `parse` reads back as this command, without the newline.
    public var line: String {
        switch self {
        case .reloadPolicy(let terminating): terminating ? "policy terminate" : "policy keep"
        case .statistics: "statistics"
        }
    }
}
