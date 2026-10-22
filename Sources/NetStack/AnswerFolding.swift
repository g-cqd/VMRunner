import Foundation

/// Decides which answered DNS queries become flow events, the way ``DenialSuppression`` does for refusals.
///
/// A guest that asks the same question again and again (a retry loop, a short TTL, a polling client) published one event, and
/// gave the app one log line, per answer. Here an answer publishes once per ``DenialSuppression/interval`` for each question,
/// response code and server; the ones held back are counted and go out as one more event (its `count` says how many) when the
/// interval ends. At most ``DenialSuppression/capacity`` keys are followed at once; past that an answer is published as it is,
/// so nothing is lost but the folding. Time is the stack's own clock, passed in.
struct AnswerFolding {
    /// What an answer is about, from the guest's side.
    struct Key: Hashable {
        let name: String
        let type: UInt16
        let responseCode: UInt8
        let server: UInt32
    }

    /// Answers that were held back, to be published as one event standing for `count` of them.
    struct Held: Equatable {
        let key: Key
        let count: Int
    }

    enum Admission: Equatable {
        /// Publish this answer. `held`, when set, is the count of the previous interval for the same key, not published yet.
        case publish(held: Held?)
        case suppress
    }

    private struct Entry {
        var until: TimeInterval
        var held: Int
    }

    private var entries: [Key: Entry] = [:]

    /// Judges one answer.
    mutating func admit(_ key: Key, now: TimeInterval) -> Admission {
        guard let entry = entries[key] else {
            guard entries.count < DenialSuppression.capacity else { return .publish(held: nil) }
            entries[key] = Entry(until: now + DenialSuppression.interval, held: 0)
            return .publish(held: nil)
        }
        if now < entry.until {
            entries[key] = Entry(until: entry.until, held: entry.held + 1)
            return .suppress
        }
        entries[key] = Entry(until: now + DenialSuppression.interval, held: 0)
        return .publish(held: entry.held > 0 ? Held(key: key, count: entry.held) : nil)
    }

    /// Forgets the keys whose interval is over and returns what was held back for them.
    mutating func expire(now: TimeInterval) -> [Held] {
        guard !entries.isEmpty else { return [] }
        let over = entries.filter { now >= $0.value.until }
        for key in over.keys { entries[key] = nil }
        return over.compactMap { $0.value.held > 0 ? Held(key: $0.key, count: $0.value.held) : nil }
    }
}
