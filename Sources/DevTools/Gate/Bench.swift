import Foundation

/// Which way a benchmark figure improves.
enum BenchDirection: String, Codable, Equatable {
    case lower
    case higher
}

/// One figure a benchmark run reported: a line of the results file that the test support's `recordBenchmark` appends to.
struct BenchResult: Decodable, Equatable {
    let name: String
    let unit: String
    let direction: BenchDirection
    let value: Double
    /// The fraction the figure may move the wrong way before it is a regression, for a figure not in the baseline yet.
    let tolerance: Double
    /// Whether a regression fails the gate, for a figure not in the baseline yet.
    let enforced: Bool

    /// The results file: one JSON object per line. A name reported twice is a mistake in the benchmarks, not a choice.
    static func parse(_ text: String) throws -> [Self] {
        var results: [Self] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let result: Self
            do {
                result = try JSONDecoder().decode(Self.self, from: Data(line.utf8))
            } catch {
                throw ToolError("unreadable benchmark result '\(line)': \(error)")
            }
            if results.contains(where: { $0.name == result.name }) { throw ToolError("benchmark '\(result.name)' was reported twice") }
            results.append(result)
        }
        return results
    }
}

/// The committed figures the gate holds the benchmarks to (`.vmr-bench.json`, beside `.vmr.json`). Each entry carries
/// its own tolerance and whether it is enforced, so loosening a noisy figure is an edit of the file, reviewed like any
/// other, and `vmr bench record` keeps such edits when it refreshes the values.
struct BenchBaseline: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var value: Double
        var unit: String
        var direction: BenchDirection
        /// The fraction the value may move the wrong way before the gate calls it a regression; 0 is exact.
        var tolerance: Double
        /// False for a figure that is reported but never fails the gate, such as a wall-clock rate.
        var enforced: Bool
    }

    static let fileName = ".vmr-bench.json"
    static let recordCommand = "swift run vmr bench record"

    var benchmarks: [String: Entry]

    static func url(root: URL) -> URL { root.appending(path: fileName) }

    /// Throws when the file is missing or unreadable.
    static func load(root: URL) throws -> Self {
        let url = url(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError("no benchmark baseline at \(url.path); record one with `\(recordCommand)`")
        }
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        } catch {
            throw ToolError("\(fileName) is not valid: \(error)")
        }
    }

    func write(root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (encoder.encode(self) + Data("\n".utf8)).write(to: Self.url(root: root))
    }

    /// The baseline after a run: every reported figure with its new value, the tolerance and enforcement of an entry
    /// that was already there (or the benchmark's own suggestion for a new one), and no entry for a figure that is no
    /// longer reported.
    func recorded(_ results: [BenchResult]) -> Self {
        var entries: [String: Entry] = [:]
        for result in results {
            let existing = benchmarks[result.name]
            entries[result.name] = Entry(
                value: (result.value * 100).rounded() / 100, unit: result.unit, direction: result.direction,
                tolerance: existing?.tolerance ?? result.tolerance, enforced: existing?.enforced ?? result.enforced)
        }
        return Self(benchmarks: entries)
    }
}

/// How one figure of a run compares with its baseline entry.
struct BenchComparison: Equatable {
    enum Verdict: Equatable {
        case unchanged
        /// Better than the baseline by more than the tolerance: the baseline should be re-recorded.
        case improved
        case regressed
        /// In the baseline, but the run did not report it.
        case missing
        /// Reported, but not in the baseline.
        case unrecorded
    }

    let name: String
    let unit: String
    let baseline: Double?
    let measured: Double?
    let verdict: Verdict
    let enforced: Bool

    /// Whether this figure fails the gate.
    var fails: Bool {
        guard enforced else { return false }
        return verdict == .regressed || verdict == .missing || verdict == .unrecorded
    }

    var line: String {
        let label =
            switch verdict {
            case .unchanged: "ok"
            case .improved: "improved"
            case .regressed: enforced ? "REGRESSED" : "slower (reported only)"
            case .missing: enforced ? "MISSING" : "missing (reported only)"
            case .unrecorded: enforced ? "UNRECORDED" : "new (reported only)"
            }
        var detail: String
        switch (measured, baseline) {
        case (let measured?, let baseline?):
            detail = "\(Self.format(measured)) \(unit) (baseline \(Self.format(baseline))"
            if baseline != 0, measured != baseline {
                detail += ", \(Self.percent((measured - baseline) / abs(baseline) * 100))"
            }
            detail += ")"
        case (let measured?, nil): detail = "\(Self.format(measured)) \(unit) (not in the baseline)"
        case (nil, let baseline?): detail = "not reported (baseline \(Self.format(baseline)) \(unit))"
        case (nil, nil): detail = ""
        }
        return "\(label.padding(toLength: 22, withPad: " ", startingAt: 0)) \(name): \(detail)"
    }

    /// A whole number plainly, anything else with one decimal.
    static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : decimal(value)
    }

    /// "+25.0%" or "-3.5%".
    static func percent(_ change: Double) -> String {
        (change < 0 ? "" : "+") + decimal(change) + "%"
    }

    /// One decimal, rounded half away from zero.
    private static func decimal(_ value: Double) -> String {
        let tenths = Int(min(abs(value) * 10, 1e15).rounded())
        return "\(value < 0 && tenths != 0 ? "-" : "")\(tenths / 10).\(tenths % 10)"
    }
}

enum Bench {
    /// Compares every figure of the run and of the baseline, ordered by name. A figure moved the wrong way when it
    /// got worse by more than its tolerance times the baseline; a tolerance of 0 makes any worsening a regression.
    static func compare(_ results: [BenchResult], against baseline: BenchBaseline) -> [BenchComparison] {
        let measured = Dictionary(uniqueKeysWithValues: results.map { ($0.name, $0) })
        let names = Set(measured.keys).union(baseline.benchmarks.keys).sorted()
        return names.map { name in
            switch (measured[name], baseline.benchmarks[name]) {
            case (let result?, let entry?):
                let worsening = entry.direction == .lower ? result.value - entry.value : entry.value - result.value
                let allowed = entry.tolerance * abs(entry.value)
                let verdict: BenchComparison.Verdict =
                    worsening > allowed ? .regressed : -worsening > allowed ? .improved : .unchanged
                return BenchComparison(
                    name: name, unit: entry.unit, baseline: entry.value, measured: result.value, verdict: verdict, enforced: entry.enforced)
            case (let result?, nil):
                return BenchComparison(
                    name: name, unit: result.unit, baseline: nil, measured: result.value, verdict: .unrecorded, enforced: result.enforced)
            case (nil, let entry?):
                return BenchComparison(
                    name: name, unit: entry.unit, baseline: entry.value, measured: nil, verdict: .missing, enforced: entry.enforced)
            case (nil, nil):
                preconditionFailure("a name from neither set")
            }
        }
    }
}
