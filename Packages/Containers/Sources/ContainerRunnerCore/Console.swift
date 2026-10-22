import Foundation

/// Where a line goes.
public enum ConsoleStream: Sendable {
    case output
    case error
}

/// Writes the runner's lines straight to the standard streams, so they interleave with a child process that shares them.
public enum Console {
    public static func line(_ text: String = "", to stream: ConsoleStream = .output) {
        let handle = stream == .output ? FileHandle.standardOutput : FileHandle.standardError
        try? handle.write(contentsOf: Data((text + "\n").utf8))
    }
}
