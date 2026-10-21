import Foundation
import dnssd

/// One blocking `DNSServiceQueryRecord` exchange, for record types `getaddrinfo` cannot return (CNAME, MX, TXT, SRV,
/// HTTPS, PTR...). `dns_sd` talks to the same system resolver (mDNSResponder) as `getaddrinfo`, so split-DNS and
/// VPN-provided DNS apply the same way, and it returns record data already uncompressed, ready to put in an answer.
///
/// The only unsafe code is the C callback and the service reference; both stay inside ``run(name:recordType:timeout:)``.
enum DNSServiceQuery {
    /// Collects what the callback delivers. A class so the C context pointer can refer to it.
    private final class Collector {
        var records: [DNSRecord] = []
        var error: DNSServiceErrorType = 0
        var gotAnswer = false
        var moreComing = false
    }

    private static let noSuchRecord: DNSServiceErrorType = -65_554
    private static let noSuchName: DNSServiceErrorType = -65_538

    /// Asks the system resolver for `recordType` records of `name`. Blocks up to `timeout` seconds.
    static func run(name: String, recordType: UInt16, timeout: TimeInterval) -> DNSLookupResult {
        let collector = Collector()
        var reference: DNSServiceRef?
        let flags = DNSServiceFlags(kDNSServiceFlagsReturnIntermediates)
        let context = unsafe Unmanaged.passUnretained(collector).toOpaque()
        let started = unsafe DNSServiceQueryRecord(
            &reference, flags, 0, name, recordType, UInt16(kDNSServiceClass_IN), queryCallback, context)
        guard started == kDNSServiceErr_NoError, let service = unsafe reference else {
            return DNSLookupResult(responseCode: DNSCode.serverFailure)
        }
        defer { unsafe DNSServiceRefDeallocate(service) }
        let descriptor = unsafe DNSServiceRefSockFD(service)
        let deadline = Date.now.addingTimeInterval(timeout)
        while collector.error == 0, !(collector.gotAnswer && !collector.moreComing) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard unsafe poll(&request, 1, Int32(min(remaining, 1) * 1_000)) >= 0 else { break }
            if request.revents & Int16(POLLIN) != 0, unsafe DNSServiceProcessResult(service) != kDNSServiceErr_NoError { break }
        }
        return result(from: collector)
    }

    private static func result(from collector: Collector) -> DNSLookupResult {
        switch collector.error {
        case 0 where collector.gotAnswer: return DNSLookupResult(responseCode: DNSCode.noError, records: collector.records)
        case noSuchRecord: return DNSLookupResult(responseCode: DNSCode.noError)
        case noSuchName: return DNSLookupResult(responseCode: DNSCode.nameError)
        default: return DNSLookupResult(responseCode: DNSCode.serverFailure)
        }
    }

    /// The C callback: no captures, so it converts to a C function pointer; everything arrives through `context`.
    private static let queryCallback: DNSServiceQueryRecordReply = { _, flags, _, error, fullName, type, _, length, data, ttl, context in
        guard let context = unsafe context else { return }
        // `context` was created from a live Collector by `run`, which outlives every callback (they fire inside
        // DNSServiceProcessResult, called from `run`).
        let collector = unsafe Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue()
        collector.moreComing = flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) != 0
        guard error == kDNSServiceErr_NoError else {
            collector.error = error
            return
        }
        guard flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, let fullName = unsafe fullName, let data = unsafe data else { return }
        var owner = unsafe String(cString: fullName).lowercased()
        if owner.hasSuffix(".") { owner.removeLast() }
        let bytes = unsafe Array(UnsafeRawBufferPointer(start: data, count: Int(length)))
        collector.records.append(DNSRecord(name: owner, type: type, ttl: ttl, data: bytes))
        collector.gotAnswer = true
    }
}
