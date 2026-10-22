/// Where the stack reports what it does. Whoever creates the stack supplies it: the app writes to its log, tests ignore
/// every line (``SilentUserNetLogger``). The stack itself knows no logging framework.
protocol UserNetLogger: Sendable {
    /// The loop thread is about to start, with this MTU.
    func stackStarting(mtu: Int)

    /// A flow was denied or ended abnormally. At most one line per destination and reason per interval reaches here
    /// (``FlowLogThrottle``).
    ///
    /// `summary` (the kind of event, the outcome and the reason) and `held` (the lines held back since the last one) are
    /// safe to log in the clear. `destination` (address, port and name) is private data and must be logged redacted.
    func flowFailed(summary: String, held: Int, destination: String)
}

/// Drops every line. The default wherever a stack is created without a logger.
struct SilentUserNetLogger: UserNetLogger {
    func stackStarting(mtu: Int) {}
    func flowFailed(summary: String, held: Int, destination: String) {}
}
