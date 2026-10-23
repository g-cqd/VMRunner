/// Calls the control service once per connection: connects, checks that the process serving the socket runs as this user,
/// sends the request with the token, reads the answer and closes. The command-line client and the MCP server use it; tests
/// give it a `connect` that returns one end of a socket pair they serve.
public struct ControlCaller: Sendable {
    private let token: String
    private let peerUser: @Sendable (Int32) -> UInt32?
    private let connect: @Sendable () throws -> ControlClient

    /// `peerUser` says which user serves a connection: by default the kernel's answer. Tests replace it.
    public init(
        token: String, peerUser: @escaping @Sendable (Int32) -> UInt32? = ControlPeer.user(of:),
        connect: @escaping @Sendable () throws -> ControlClient
    ) {
        self.token = token
        self.peerUser = peerUser
        self.connect = connect
    }

    /// A caller of the service listening at `socket`.
    public init(token: String, socket: String) {
        self.init(token: token) { try ControlClient.connect(to: socket) }
    }

    /// Calls `method` with `params` and this caller's token (a `token` in `params` is replaced) and returns the answer, an
    /// error answer included. Throws when the service cannot be reached, is served by another user, or does not answer.
    public func call(_ method: ControlMethod, params: [String: RPCValue] = [:]) throws -> ControlAnswer {
        let client = try connect()
        defer { client.close() }
        guard peerUser(client.descriptor) == ControlPeer.currentUser else { throw ControlClientError.peerIsAnotherUser }
        return try client.call(method.rawValue, params: params.merging(["token": .string(token)]) { _, ours in ours })
    }
}
