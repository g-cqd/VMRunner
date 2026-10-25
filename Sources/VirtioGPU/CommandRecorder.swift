/// The device's bounded record of a run: the command log, the time of each request still in it, and the answers to the
/// question of how the guest is notified. Two moments are watched: the first request after the first display-information
/// answer (the guest waits for that answer, so a later request shows that giving an element back reached it), and the first
/// display-information request after the host changed the configuration space (the guest asks again only when the change
/// notified it).
package struct CommandRecorder: Sendable {
    package private(set) var log: CommandLog
    /// Milliseconds since the start of the run, at `sequence % capacity`: the time of every entry the log still holds.
    private var times: [UInt64]
    private var firstSeen: Set<UInt32> = []
    package private(set) var displayInfoAnsweredAt: UInt64?
    package private(set) var requestAfterDisplayInfoAt: UInt64?
    package private(set) var configurationUpdatedAt: UInt64?
    package private(set) var displayInfoAfterUpdateAt: UInt64?

    package init(capacity: Int = 1024) {
        log = CommandLog(capacity: capacity)
        times = Array(repeating: 0, count: log.capacity)
    }

    /// Records one handled request and returns the lines worth printing now: the first request of each known type and each
    /// answer to the notification question, so what is printed stays bounded whatever the guest sends.
    package mutating func record(_ entry: CommandLogEntry, atMilliseconds now: UInt64) -> [String] {
        log.append(entry)
        times[Int(entry.sequence % UInt64(log.capacity))] = now
        var lines: [String] = []
        if let type = GPUCommandType(rawValue: entry.commandType), firstSeen.insert(entry.commandType).inserted {
            lines.append("first \(type) request at \(now) ms")
        }
        if let answered = displayInfoAnsweredAt, requestAfterDisplayInfoAt == nil {
            requestAfterDisplayInfoAt = now
            lines.append("the guest sent a request \(now - answered) ms after the display information was given back")
        }
        let isDisplayInfo = entry.commandType == GPUCommandType.getDisplayInfo.rawValue
        if isDisplayInfo, entry.responseType == .okDisplayInfo, displayInfoAnsweredAt == nil {
            displayInfoAnsweredAt = now
        }
        if isDisplayInfo, let updated = configurationUpdatedAt, displayInfoAfterUpdateAt == nil, now >= updated {
            displayInfoAfterUpdateAt = now
            lines.append("display info requested again after the configuration update, \(now - updated) ms later")
        }
        return lines
    }

    /// Notes that the host changed the configuration space; only the first change is watched.
    package mutating func noteConfigurationUpdate(atMilliseconds now: UInt64) {
        if configurationUpdatedAt == nil { configurationUpdatedAt = now }
    }

    /// The text of `commands.log`: the counts, the answers to the notification question, the `extra` lines the caller adds,
    /// then one line per request still held, oldest first.
    package func report(extra: [String] = []) -> String {
        var lines = log.summary()
        lines.append("display info answered at: \(Self.text(displayInfoAnsweredAt))")
        lines.append("first request after that answer at: \(Self.text(requestAfterDisplayInfoAt))")
        lines.append("configuration updated at: \(Self.text(configurationUpdatedAt))")
        lines.append("display info requested after the update at: \(Self.text(displayInfoAfterUpdateAt))")
        lines += extra
        lines.append("last \(log.entries.count) requests (time ms, sequence, queue, type, resource, answer, bytes):")
        for entry in log.entries {
            let time = times[Int(entry.sequence % UInt64(log.capacity))]
            let type = "0x" + String(entry.commandType, radix: 16)
            let answer = entry.responseType.map { "0x" + String($0.rawValue, radix: 16) } ?? "-"
            lines.append("\(time) #\(entry.sequence) \(entry.queue) \(type) \(entry.resourceID) \(answer) \(entry.byteCount)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func text(_ milliseconds: UInt64?) -> String {
        milliseconds.map { "\($0) ms" } ?? "never"
    }
}
