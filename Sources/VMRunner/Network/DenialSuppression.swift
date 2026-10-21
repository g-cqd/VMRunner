import Foundation

/// Decides which refusals become flow events.
///
/// A guest can ask for a refused destination as fast as it can send frames, and every refusal used to publish an
/// event (and a log line) that the app then queued, logged and showed. Here a refusal publishes once per
/// ``interval`` for each ``Endpoint``; the ones held back are counted, and the count goes out as one more event when the
/// interval ends, so the log can say "x N" and nothing is lost but the repetition. Distinct endpoints are limited to
/// ``capacity`` at a time, so a guest that sweeps addresses and ports cannot buy an event per probe either.
///
/// One table serves every kind of refusal: TCP SYNs, UDP datagrams (including the ones to a gateway port nothing
/// serves), echo requests and DNS questions. A policy change clears it, so a refusal is never remembered past the
/// policy that made it. Time is the stack's own clock, passed in.
struct DenialSuppression {
    /// What a refusal is about, from the guest's side: the same destination over the same transport. The guest's own
    /// port is not part of it, because a guest that rotates source ports must not get a new event for each. A DNS
    /// refusal is about a name.
    struct Endpoint: Hashable {
        let transport: FlowTransport
        let address: UInt32
        let port: UInt16
        let name: String?
    }

    /// Refusals that were held back, to be published as one event standing for `count` attempts.
    struct Held: Equatable {
        let endpoint: Endpoint
        let denial: FlowDenial
        let name: String?
        let count: Int
    }

    enum Admission: Equatable {
        /// Publish this refusal. `held`, when set, is the count of the previous interval for this endpoint, which was
        /// not published yet.
        case publish(held: Held?)
        case suppress
    }

    static let interval: TimeInterval = 5
    static let capacity = 256

    private struct Entry {
        var denial: FlowDenial
        var name: String?
        var until: TimeInterval
        var held: Int
    }

    private var entries: [Endpoint: Entry] = [:]

    /// Judges one refusal of `endpoint`. A refusal for another reason than the last one published is a new thing to say,
    /// so it is published at once.
    mutating func admit(_ endpoint: Endpoint, _ denial: FlowDenial, name: String?, now: TimeInterval) -> Admission {
        guard var entry = entries[endpoint] else {
            if entries.count >= Self.capacity { dropExpired(now: now) }
            guard entries.count < Self.capacity else { return .suppress }
            entries[endpoint] = Entry(denial: denial, name: name, until: now + Self.interval, held: 0)
            return .publish(held: nil)
        }
        if now < entry.until, entry.denial == denial {
            entry.held += 1
            entries[endpoint] = entry
            return .suppress
        }
        let held = entry.held > 0 ? Held(endpoint: endpoint, denial: entry.denial, name: entry.name, count: entry.held) : nil
        entries[endpoint] = Entry(denial: denial, name: name, until: now + Self.interval, held: 0)
        return .publish(held: held)
    }

    /// Counts and holds back a refusal of `endpoint` without judging it, when one was published within the interval.
    /// Lets the caller skip the work of deciding again.
    mutating func absorbs(_ endpoint: Endpoint, now: TimeInterval) -> Bool {
        guard var entry = entries[endpoint], now < entry.until else { return false }
        entry.held += 1
        entries[endpoint] = entry
        return true
    }

    /// Removes the endpoints whose interval is over; returns what was held back for them.
    mutating func expire(now: TimeInterval) -> [Held] {
        guard !entries.isEmpty else { return [] }
        let over = entries.filter { now >= $0.value.until }
        for endpoint in over.keys { entries[endpoint] = nil }
        return over.compactMap { Self.held($0.key, $0.value) }
    }

    /// Forgets everything and returns what was held back.
    mutating func drain() -> [Held] {
        defer { entries.removeAll(keepingCapacity: true) }
        return entries.compactMap { Self.held($0.key, $0.value) }
    }

    private mutating func dropExpired(now: TimeInterval) {
        for (endpoint, entry) in entries where now >= entry.until { entries[endpoint] = nil }
    }

    private static func held(_ endpoint: Endpoint, _ entry: Entry) -> Held? {
        entry.held > 0 ? Held(endpoint: endpoint, denial: entry.denial, name: entry.name, count: entry.held) : nil
    }

    var count: Int { entries.count }
}
