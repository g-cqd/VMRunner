/// The names of the probe's checks: the helper reports them as `check` in its `probe` events, and the launcher's report
/// looks them up, so the two cannot drift apart.
public enum ProbeCheck {
    public static let socketPair = "create a datagram socket pair"
    public static let tcpConnect = "connect a TCP socket to 127.0.0.1:9"
    public static let udpSend = "send a UDP datagram to 127.0.0.1:9"
    public static let udpBind = "bind a UDP socket to 127.0.0.1"
    public static let icmpConnect = "connect an ICMP echo socket to 127.0.0.1"
    public static let localHost = "localhost"
    public static let remoteHost = "example.com"

    public static func resolve(_ host: String) -> String {
        "resolve \(host)"
    }

    /// What a user-mode network stack needs from the process that hosts it: the guest-facing socket pair, and one outbound
    /// socket of each kind the stack opens for a guest connection (TCP, UDP, ICMP echo).
    public static let userModeStack = [socketPair, tcpConnect, udpSend, icmpConnect]
}
