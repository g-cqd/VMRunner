import Foundation

/// Puts the terminal on standard input into raw mode (no echo, no line editing, no signal keys) while `body` runs, then puts
/// it back. Does nothing when standard input is not a terminal.
enum TerminalMode {
    static func raw<Result>(_ body: () throws -> Result) rethrows -> Result {
        var original = termios()
        // `tcgetattr` fills one termios; `tcsetattr` reads one.
        guard isatty(STDIN_FILENO) == 1, unsafe tcgetattr(STDIN_FILENO, &original) == 0 else { return try body() }
        var raw = original
        unsafe cfmakeraw(&raw)
        guard unsafe tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return try body() }
        defer { _ = unsafe tcsetattr(STDIN_FILENO, TCSANOW, &original) }
        return try body()
    }
}
