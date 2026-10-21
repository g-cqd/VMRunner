import Foundation

/// Resolves names for the DNS proxy using the host's own resolution machinery.
///
/// Implementations must be safe to call concurrently and must not block a cooperative-pool thread (a blocking
/// system call belongs on its own thread). Resolution errors are expressed as response codes, not thrown.
protocol HostNameResolver: Sendable {
    func lookup(name: String, recordType: UInt16) async -> DNSLookupResult
}

/// The thread-safe command queue between the outside world and the loop thread.
enum UserNetCommand: Sendable {
    case stop
    case setPolicy(NetworkPolicy, ExistingFlowAction)
    case hostPathChanged(ExistingFlowAction)
    case nameResolved(token: UInt64, result: DNSLookupResult)
}
