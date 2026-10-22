/// Result of a non-blocking read or write on a host socket.
enum HostIOResult: Hashable, Sendable {
    /// This many bytes (always greater than zero) were transferred.
    case transferred(Int)
    /// Nothing can move right now.
    case wouldBlock
    /// A read found the peer closed its sending side (orderly).
    case endOfStream
    /// The operation failed with this `errno`.
    case failed(Int32)
}

/// The kind of host socket behind a datagram flow.
enum DatagramKind: Hashable, Sendable {
    case udp
    /// An unprivileged ICMP echo socket: writes take a whole ICMP message, reads return one.
    case icmpEcho
}

/// Everything the core needs from the outside world. The I/O shell implements it with real sockets; tests with a
/// recording fake.
///
/// ## Contract
/// - Methods are called from the single thread that owns the core; implementations need no locking against it.
/// - Nothing here blocks. Reads and writes are non-blocking and report ``HostIOResult``.
/// - Views passed in are valid only for the duration of the call.
/// - `token` values are chosen by the core, unique for the life of the core, and used for streams and datagrams
///   alike. Readiness comes back as calls on the core (`streamReadable`, ...).
/// - The core stays allocation-free per packet in steady state: the only allocating calls are `resolve`, `publish`
///   (flow lifecycle and DNS events), and flow setup.
protocol UserNetHost: AnyObject {
    /// Hands one complete Ethernet frame to the guest. The host copies it if it cannot send right now.
    func sendToGuest(_ frame: ByteView)

    // MARK: Streams (TCP)

    /// Starts a non-blocking connect to `address:port`. The outcome arrives as `streamConnected(token:error:)`.
    func openStream(token: UInt64, address: UInt32, port: UInt16)
    func writeStream(token: UInt64, _ bytes: ByteView) -> HostIOResult
    func readStream(token: UInt64, into buffer: MutableByteView) -> HostIOResult
    /// Half-close: no more writes from the guest.
    func shutdownStreamWrite(token: UInt64)
    /// Closes the socket. `abort` discards unsent data and resets the peer instead of finishing gracefully.
    func closeStream(token: UInt64, abort: Bool)
    /// Which readiness the core wants to hear about.
    func setStreamInterest(token: UInt64, read: Bool, write: Bool)

    // MARK: Datagrams (UDP and ICMP echo)

    /// Opens a connected datagram socket to `address:port` (port is ignored for ICMP). `false` if it could not.
    func openDatagram(token: UInt64, kind: DatagramKind, address: UInt32, port: UInt16) -> Bool
    func writeDatagram(token: UInt64, _ bytes: ByteView) -> HostIOResult
    func readDatagram(token: UInt64, into buffer: MutableByteView) -> HostIOResult
    func closeDatagram(token: UInt64)

    // MARK: Names and observation

    /// Starts resolving `name` for `recordType`; the answer arrives as `nameResolved(token:result:)`.
    func resolve(token: UInt64, name: String, recordType: UInt16)
    func publish(_ event: FlowEvent)
    func publish(vpnState: GuestVPNState)
}
