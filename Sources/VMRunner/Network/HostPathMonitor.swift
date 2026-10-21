import Foundation
import Network

/// What matters about the Mac's network path for deciding whether open flows can survive: whether any path exists, and
/// which interfaces and gateways it would use.
struct HostPathSnapshot: Hashable, Sendable {
    var isSatisfied: Bool
    var interfaces: [String]
    var gateways: [String]

    init(isSatisfied: Bool, interfaces: [String], gateways: [String] = []) {
        self.isSatisfied = isSatisfied
        self.interfaces = interfaces
        self.gateways = gateways
    }

    init(_ path: NWPath) {
        self.init(
            isSatisfied: path.status == .satisfied, interfaces: path.availableInterfaces.map(\.name),
            gateways: path.gateways.map { "\($0)" })
    }
}

/// Watches the Mac's network path and yields once per change.
///
/// A "change" is the path becoming (un)satisfied, or its list of usable interfaces or gateways changing: a Wi-Fi
/// network switch, Ethernet plugged in or removed, a VPN connecting or disconnecting. The first snapshot is the
/// baseline and yields nothing; a snapshot equal to the previous one yields nothing. `NWPathMonitor` is consumed as
/// an `AsyncSequence`, so no dispatch queue is needed.
enum HostPathMonitor {
    /// Changes of the real system path.
    static func changes() -> AsyncStream<Void> {
        changes(in: NWPathMonitor().map { HostPathSnapshot($0) })
    }

    /// Changes in an arbitrary sequence of path snapshots (the seam tests use).
    static func changes(in snapshots: some AsyncSequence<HostPathSnapshot, Never> & Sendable) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let watcher = Task {
                var previous: HostPathSnapshot?
                for await snapshot in snapshots {
                    if let previous, previous != snapshot { continuation.yield() }
                    previous = snapshot
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in watcher.cancel() }
        }
    }
}
