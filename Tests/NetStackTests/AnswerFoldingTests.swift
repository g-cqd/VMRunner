import Foundation
import Testing

@testable import NetStack

struct AnswerFoldingTests {
    private let key = AnswerFolding.Key(name: "host.test", type: 1, responseCode: 0, server: 1)

    /// `#expect` cannot hold a mutating call, so the table is driven through these.
    private func admit(_ table: inout AnswerFolding, _ key: AnswerFolding.Key, at now: TimeInterval) -> AnswerFolding.Admission {
        table.admit(key, now: now)
    }

    private func expire(_ table: inout AnswerFolding, at now: TimeInterval) -> [AnswerFolding.Held] {
        table.expire(now: now)
    }

    @Test func anAnswerIsPublishedOncePerIntervalAndTheRestAreCounted() {
        var table = AnswerFolding()
        #expect(admit(&table, key, at: 0) == .publish(held: nil))
        for second in 1...4 { #expect(admit(&table, key, at: TimeInterval(second)) == .suppress) }
        #expect(admit(&table, key, at: 6) == .publish(held: AnswerFolding.Held(key: key, count: 4)), "the next one carries the count")
    }

    @Test func anotherNameTypeCodeOrServerIsAnotherAnswer() {
        var table = AnswerFolding()
        _ = admit(&table, key, at: 0)
        let others = [
            AnswerFolding.Key(name: "other.test", type: 1, responseCode: 0, server: 1),
            AnswerFolding.Key(name: "host.test", type: 28, responseCode: 0, server: 1),
            AnswerFolding.Key(name: "host.test", type: 1, responseCode: 3, server: 1),
            AnswerFolding.Key(name: "host.test", type: 1, responseCode: 0, server: 2),
        ]
        for other in others { #expect(admit(&table, other, at: 1) == .publish(held: nil)) }
    }

    @Test func whatWasHeldGoesOutWhenTheIntervalEndsAndOnlyOnce() {
        var table = AnswerFolding()
        _ = admit(&table, key, at: 0)
        _ = admit(&table, key, at: 1)
        #expect(expire(&table, at: 4).isEmpty)
        #expect(expire(&table, at: 5) == [AnswerFolding.Held(key: key, count: 1)])
        #expect(expire(&table, at: 10).isEmpty)
        #expect(admit(&table, key, at: 11) == .publish(held: nil))
    }

    @Test func pastItsCapacityAnAnswerIsPublishedAsItIs() {
        var table = AnswerFolding()
        for index in 0..<DenialSuppression.capacity {
            _ = admit(&table, AnswerFolding.Key(name: "n\(index).test", type: 1, responseCode: 0, server: 1), at: 0)
        }
        let extra = AnswerFolding.Key(name: "extra.test", type: 1, responseCode: 0, server: 1)
        #expect(admit(&table, extra, at: 0) == .publish(held: nil))
        #expect(admit(&table, extra, at: 1) == .publish(held: nil), "it is not followed, so it is never held back")
    }
}
