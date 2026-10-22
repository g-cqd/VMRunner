extension InputLatencyStats {
    /// A nanosecond count as milliseconds with three decimals, such as `0.125ms`.
    static func milliseconds(_ nanoseconds: UInt64) -> String {
        let microseconds = nanoseconds / 1_000 + (nanoseconds % 1_000 >= 500 ? 1 : 0)
        let fraction = String(microseconds % 1_000)
        return "\(microseconds / 1_000).\(String(repeating: "0", count: 3 - fraction.count))\(fraction)ms"
    }

    /// The whole picture in one line for the log, a file or the quit message: for each series the count, p50, p90, p99, the
    /// maximum and how many values passed the threshold, then the worst stalls with the instrumented work inside them.
    func summaryLine(label: String) -> String {
        let over = Self.milliseconds(busy.threshold)
        var series = InputKind.allCases.map { Self.describe($0.label, events($0)) }
        series.append(Self.describe("main busy", busy))
        var line = "input latency [\(label), over \(over)]: " + series.joined(separator: "; ")
        if !worstStalls.isEmpty {
            line += " | worst: " + worstStalls.map(Self.describe).joined(separator: "; ")
        }
        return line
    }

    private static func describe(_ name: String, _ histogram: LatencyHistogram) -> String {
        guard histogram.samples > 0 else { return "\(name) n=0" }
        let figures = [50.0, 90, 99].map { "p\(Int($0))=\(milliseconds(histogram.percentile($0)))" }.joined(separator: " ")
        return "\(name) n=\(histogram.samples) \(figures) max=\(milliseconds(histogram.maximum)) over=\(histogram.overThreshold)"
    }

    private static func describe(_ stall: LoopStall) -> String {
        let work = stall.work.map { "\($0.name) \(milliseconds($0.duration))\($0.count > 1 ? " x\($0.count)" : "")" }
        let detail = ["wake \(milliseconds(stall.wake))", "\(stall.passes) passes"] + work
        return "\(milliseconds(stall.duration)) (\(detail.joined(separator: ", ")))"
    }
}
