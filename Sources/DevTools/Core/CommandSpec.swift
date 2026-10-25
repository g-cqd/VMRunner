import Foundation

/// A child process to run.
struct CommandSpec: Sendable {
    /// A program name resolved through `PATH`, or a path.
    var executable: String
    var arguments: [String] = []
    var workingDirectory: URL?
    /// Variables set on top of the inherited environment, or on top of nothing when `inheritEnvironment` is false.
    var environment: [String: String] = [:]
    var inheritEnvironment = true
    /// With `.inherit` output: the child reads this process's standard input instead of an empty one.
    var inheritsInput = false
    /// After this long the process gets SIGTERM, then SIGKILL, and the result reports `timedOut`.
    var timeout: Duration?

    /// The environment the child will see.
    var effectiveEnvironment: [String: String] {
        let base = inheritEnvironment ? ProcessInfo.processInfo.environment : [:]
        return base.merging(environment) { _, override in override }
    }
}

/// What happens to the child's standard output and error.
enum OutputMode: Sendable {
    /// The child writes straight to this process's descriptors: nothing is buffered, nothing is copied.
    case inherit
    /// Both streams are collected in memory. Only for short outputs; stdin is closed.
    case capture
    /// Like `.inherit`, but line by line: each line of either stream is written to the matching descriptor of this
    /// process and also handed to the observer, which two tasks may call at the same time.
    case stream(@Sendable (String) -> Void)
}

struct CommandResult: Sendable {
    /// The exit status, or 128 plus the signal number when the process was killed by a signal (as a shell reports it).
    let status: Int32
    let standardOutput: String
    let standardError: String
    let timedOut: Bool

    var succeeded: Bool { status == 0 && !timedOut }
}
