import Foundation
import Synchronization

/// The host's own resolver, which asks the system resolver (mDNSResponder), so scoped and split-DNS
/// configurations, VPN-provided DNS servers, `/etc/hosts` and search domains all apply exactly as they do for
/// the Mac's own apps.
///
/// - A questions use `getaddrinfo` (which also consults `/etc/hosts` and returns the canonical name).
/// - Every other type (CNAME, MX, TXT, SRV, HTTPS, PTR...) uses `DNSServiceQueryRecord` (``DNSServiceQuery``).
///
/// Both block, so each lookup runs on its own short-lived thread (at most ``maximumConcurrent`` at a time; excess
/// lookups answer SERVFAIL immediately) and the caller awaits a continuation: no cooperative-pool thread is ever
/// blocked.
struct SystemNameResolver: HostNameResolver {
    static let maximumConcurrent = 32
    private static let queryTimeout: TimeInterval = 4
    private static let inFlight = Mutex(0)

    func lookup(name: String, recordType: UInt16) async -> DNSLookupResult {
        let admitted = Self.inFlight.withLock { count -> Bool in
            guard count < Self.maximumConcurrent else { return false }
            count += 1
            return true
        }
        guard admitted else { return DNSLookupResult(responseCode: DNSCode.serverFailure) }
        return await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let result =
                    recordType == DNSCode.typeA
                    ? Self.resolveIPv4(name) : DNSServiceQuery.run(name: name, recordType: recordType, timeout: Self.queryTimeout)
                Self.inFlight.withLock { $0 -= 1 }
                continuation.resume(returning: result)
            }
        }
    }

    private static func resolveIPv4(_ name: String) -> DNSLookupResult {
        let answer = SystemResolverCalls.addresses(of: name)
        switch answer.status {
        case .found:
            let owner = answer.canonicalName.flatMap { $0 == name ? nil : $0 }
            var records: [DNSRecord] = []
            if let owner, let encoded = DNSWire.encodeName(owner) {
                records.append(DNSRecord(name: name, type: DNSCode.typeCNAME, ttl: 60, data: encoded))
            }
            for address in answer.addresses {
                let bytes = [UInt8(address >> 24), UInt8((address >> 16) & 0xFF), UInt8((address >> 8) & 0xFF), UInt8(address & 0xFF)]
                records.append(DNSRecord(name: owner ?? name, type: DNSCode.typeA, ttl: 60, data: bytes))
            }
            return DNSLookupResult(responseCode: DNSCode.noError, records: records)
        case .noSuchName: return DNSLookupResult(responseCode: DNSCode.nameError)
        case .noData: return DNSLookupResult(responseCode: DNSCode.noError)
        case .failure: return DNSLookupResult(responseCode: DNSCode.serverFailure)
        }
    }
}

/// The one place `getaddrinfo` and its linked list are touched.
enum SystemResolverCalls {
    enum Status {
        case found, noSuchName, noData, failure
    }

    struct Answer {
        var status: Status
        var addresses: [UInt32] = []
        var canonicalName: String?
    }

    /// Blocking: resolves `name` to its IPv4 addresses and canonical name through the system resolver.
    static func addresses(of name: String) -> Answer {
        var hints = unsafe addrinfo()
        unsafe hints.ai_family = AF_INET
        unsafe hints.ai_socktype = SOCK_STREAM
        unsafe hints.ai_flags = AI_CANONNAME
        var list: UnsafeMutablePointer<addrinfo>?
        let code = unsafe getaddrinfo(name, nil, &hints, &list)
        guard code == 0, let head = unsafe list else {
            switch code {
            case EAI_NONAME: return Answer(status: .noSuchName)
            case EAI_NODATA: return Answer(status: .noData)
            default: return Answer(status: .failure)
            }
        }
        defer { unsafe freeaddrinfo(head) }
        var answer = Answer(status: .found)
        var cursor: UnsafeMutablePointer<addrinfo>? = unsafe head
        while let entry = unsafe cursor {
            // `ai_addr` of an AF_INET entry points at a `sockaddr_in`.
            if unsafe entry.pointee.ai_family == AF_INET, let socketAddress = unsafe entry.pointee.ai_addr {
                let raw = unsafe socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { unsafe $0.pointee.sin_addr.s_addr }
                answer.addresses.append(UInt32(bigEndian: raw))
            }
            if answer.canonicalName == nil, let canonical = unsafe entry.pointee.ai_canonname {
                answer.canonicalName = unsafe String(cString: canonical).lowercased()
            }
            unsafe cursor = entry.pointee.ai_next
        }
        return answer
    }
}
