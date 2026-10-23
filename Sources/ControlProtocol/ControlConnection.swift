import Foundation
import GuestConsole

/// Who is on the other end of a local socket.
public enum ControlPeer {
    /// The user id the kernel reports for the process on the other end (`getpeereid`), or nil when it cannot say.
    public static func user(of descriptor: Int32) -> UInt32? {
        var user: uid_t = 0
        var group: gid_t = 0
        // `getpeereid` writes one uid and one gid.
        guard unsafe getpeereid(descriptor, &user, &group) == 0 else { return nil }
        return user
    }

    /// The user this process runs as.
    public static var currentUser: UInt32 { geteuid() }
}

/// Serves one connected client (ADR-0056): checks that it runs as the allowed user, then reads requests line by line within
/// the limits and writes each answer. The descriptor is closed when it returns.
public struct ControlConnection: Sendable {
    let dispatcher: ControlDispatcher
    let limits: ControlLimits
    let peerUser: @Sendable (Int32) -> UInt32?
    let allowedUser: UInt32
    let sleep: @Sendable (Duration) async throws -> Void

    /// `peerUser` and `allowedUser` say who the client is and who it must be: by default the kernel's answer for the socket
    /// and this process's user. `sleep` measures a request's time limit. Tests replace them.
    public init(
        dispatcher: ControlDispatcher, limits: ControlLimits = ControlLimits(),
        peerUser: @escaping @Sendable (Int32) -> UInt32? = ControlPeer.user(of:), allowedUser: UInt32 = ControlPeer.currentUser,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.dispatcher = dispatcher
        self.limits = limits
        self.peerUser = peerUser
        self.allowedUser = allowedUser
        self.sleep = sleep
    }

    /// Serves `descriptor` until the client closes, sends too much, stays silent past the read limit or has sent
    /// `limits.requestsPerConnection` requests; then closes it. `isOpen` is asked once a request has been read: when it says no
    /// (the listener was stopped) the connection closes without answering, so turning the service off cuts open connections off.
    public func serve(_ descriptor: Int32, while isOpen: @Sendable () -> Bool = { true }) async {
        defer { ConsoleSocket.close(descriptor) }
        let peer = peerUser(descriptor)
        guard peer == allowedUser else {
            dispatcher.report(ControlDenial(reason: .otherUser, peerUser: peer))
            return
        }
        let limits = self.limits
        var buffer = LineBuffer(limit: limits.requestBytes)
        for _ in 0..<limits.requestsPerConnection {
            let (read, rest) = await runOnThread { [buffer] in
                var pending = buffer
                let read = LineIO.readLine(
                    from: descriptor, into: &pending, readBytes: limits.readBytes, timeoutMilliseconds: limits.readTimeoutMilliseconds)
                return (read, pending)
            }
            buffer = rest
            guard isOpen(), let outcome = await reply(to: read) else { return }
            if let line = outcome.line {
                let stall = limits.writeStallMilliseconds
                guard await runOnThread({ LineIO.write(line, to: descriptor, stallMilliseconds: stall) }) else { return }
            }
            if outcome.closes { return }
        }
    }

    /// What to send back for one read, and whether the connection ends after it; nil ends it without a word.
    private func reply(to read: LineRead) async -> (line: Data?, closes: Bool)? {
        switch read {
        case .line(let bytes):
            return (await answer(Data(bytes)), false)
        case .tooLong:
            let error = RPCError.invalidRequest.with("the request is longer than \(limits.requestBytes) bytes")
            return (RPCResponse(id: .null, error: error).encoded(), true)
        case .closed, .timedOut, .failed:
            return nil
        }
    }

    /// The answer line to one request line; nil for a notification, which is neither run nor answered.
    func answer(_ line: Data) async -> Data? {
        switch RPCMessage.parse(line) {
        case .invalid(let response):
            return response.encoded()
        case .notification:
            return nil
        case .request(let request):
            let dispatcher = self.dispatcher
            let response = await withDeadline(limits.requestTimeout, sleep: sleep) { await dispatcher.answer(request) }
            return (response ?? RPCResponse(id: request.id, error: .timedOut)).encoded()
        }
    }
}
