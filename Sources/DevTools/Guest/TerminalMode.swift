import Foundation

/// Puts a terminal into raw mode (no echo, no line editing, no signal keys) while `body` runs, then puts it back, whether
/// `body` returns or throws. Does nothing when `descriptor` is not a terminal. A signal that would end the process is not
/// covered here: the console client turns those into an ordinary end of `body` with ``SignalWatch``.
enum TerminalMode {
    static func raw<Result>(on descriptor: Int32 = STDIN_FILENO, _ body: () throws -> Result) rethrows -> Result {
        var original = termios()
        // `tcgetattr` fills one termios; `tcsetattr` reads one.
        guard isatty(descriptor) == 1, unsafe tcgetattr(descriptor, &original) == 0 else { return try body() }
        var raw = original
        unsafe cfmakeraw(&raw)
        guard unsafe tcsetattr(descriptor, TCSANOW, &raw) == 0 else { return try body() }
        defer { _ = unsafe tcsetattr(descriptor, TCSANOW, &original) }
        return try body()
    }
}
