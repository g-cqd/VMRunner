/// A failure the command line reports to the user as `error: <message>` and turns into an exit status.
struct ToolError: Error, CustomStringConvertible {
    /// `sysexits.h` EX_USAGE, which the former scripts used for bad arguments.
    static let usageStatus: Int32 = 64

    let message: String
    let status: Int32

    init(_ message: String, status: Int32 = 1) {
        self.message = message
        self.status = status
    }

    static func usage(_ message: String) -> Self {
        Self(message, status: usageStatus)
    }

    var description: String { message }
}
