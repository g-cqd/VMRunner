/// How much the control service accepts and how long it waits (ADR-0056). Nothing a client sends grows a buffer past these.
public struct ControlLimits: Equatable, Sendable {
    /// The longest request line in bytes, its newline excluded.
    public var requestBytes = 65_536
    /// The most bytes one read takes from a connection.
    public var readBytes = 4_096
    /// Requests one connection may send before it is closed.
    public var requestsPerConnection = 64
    /// Connections served at once; one more is closed at once.
    public var connections = 4
    /// How long a connection may take to send a whole request before it is closed.
    public var readTimeoutMilliseconds: Int32 = 10_000
    /// How long a client that does not read its answer is waited for before it is dropped.
    public var writeStallMilliseconds: Int32 = 2_000
    /// How long a request may take to be answered; past it the answer says it timed out.
    public var requestTimeout: Duration = .seconds(120)

    public init() {}
}
