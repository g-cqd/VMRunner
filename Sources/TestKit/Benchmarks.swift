// `public import`: ``Trait/benchmarksRequested`` is a Swift Testing trait.
public import Testing

#if canImport(Darwin)
    internal import Darwin
#elseif canImport(Glibc)
    internal import Glibc
#endif

/// The file benchmarks append their results to: the value of `VMR_BENCH_OUTPUT`, which `vmr check bench` and
/// `vmr bench record` set. `nil` in an ordinary test run, and then no benchmark runs.
public var benchmarkResultsPath: String? {
    guard let value = getenv("VMR_BENCH_OUTPUT") else { return nil }
    let path = String(cString: value)
    return path.isEmpty ? nil : path
}

extension Trait where Self == ConditionTrait {
    /// Runs a benchmark only when a results file is named (``benchmarkResultsPath``): Swift Testing cannot exclude a tag
    /// from a run, so the default `swift test` skips benchmarks through this trait.
    public static var benchmarksRequested: Self {
        .enabled(if: benchmarkResultsPath != nil, "benchmarks run through `swift run vmr check bench`")
    }
}

/// One measured figure of a benchmark, as `vmr` reads it back.
public struct BenchmarkResult: Sendable {
    /// Which way is better. A figure that moves the other way is a regression.
    public enum Direction: String, Sendable {
        case lower
        case higher
    }

    /// Dotted and stable: it is the key of the committed baseline.
    public var name: String
    public var unit: String
    public var direction: Direction
    public var value: Double
    /// The fraction the figure may move the wrong way before it counts as a regression, written into the baseline when
    /// the figure is first recorded. 0 for a deterministic count, a few percent for retired instructions.
    public var tolerance: Double
    /// Whether a regression fails the gate. A wall-clock time depends on what else the machine runs, so it is reported
    /// and never fails; a count of instructions or allocations is enforced.
    public var enforced: Bool

    public init(name: String, unit: String, direction: Direction, value: Double, tolerance: Double = 0, enforced: Bool = true) {
        self.name = name
        self.unit = unit
        self.direction = direction
        self.value = value
        self.tolerance = tolerance
        self.enforced = enforced
    }
}

/// Appends results to the file `vmr` reads, one JSON object per line: `{"name":..,"unit":..,"direction":..,"tolerance":..,
/// "enforced":..,"value":..}`. Does nothing when no file is named.
public func recordBenchmark(_ result: BenchmarkResult) {
    guard let path = benchmarkResultsPath else { return }
    for text in [result.name, result.unit] {
        precondition(!text.contains { $0 == "\"" || $0 == "\\" || $0.isNewline }, "'\(text)' needs JSON escaping")
    }
    let line =
        "{\"name\":\"\(result.name)\",\"unit\":\"\(result.unit)\",\"direction\":\"\(result.direction.rawValue)\","
        + "\"tolerance\":\(result.tolerance),\"enforced\":\(result.enforced),\"value\":\(result.value)}\n"
    // One `write` on an `O_APPEND` descriptor lands whole, so benchmarks running at once cannot interleave their lines.
    let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    precondition(descriptor >= 0, "cannot open the benchmark results file \(path)")
    defer { close(descriptor) }
    let bytes = Array(line.utf8)
    let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    precondition(written == bytes.count, "cannot write the benchmark results file \(path)")
}

/// The best of several rounds of the same work.
public struct Rate: Sendable {
    /// Units of work per second in the fastest round.
    public var perSecond: Double
    /// Retired instructions per unit in the round that retired the fewest; `nil` where the platform does not report
    /// them. Unlike a time it hardly depends on what else the machine is doing.
    public var instructionsPerUnit: Double?
}

/// Runs `body`, which does `units` units of work, `rounds` times and keeps the best round: noise from the machine only
/// ever slows a round, so the fastest is the closest to the work's own cost. Measured with ``ProcessProbe``: wall time,
/// and retired instructions for the whole process, so run it with nothing else going on.
public func measureRate(units: Double, rounds: Int = 5, _ body: () async throws -> Void) async rethrows -> Rate {
    var fastest = Double.infinity
    var fewest = UInt64.max
    for _ in 0..<rounds {
        let start = ProcessProbe.snapshot()
        try await body()
        let delta = ProcessProbe.delta(from: start, to: ProcessProbe.snapshot())
        fastest = min(fastest, Double(delta.wallNanos) / 1e9)
        fewest = min(fewest, delta.instructions)
    }
    return Rate(
        perSecond: units / max(fastest, 1e-9),
        instructionsPerUnit: fewest == 0 || fewest == .max ? nil : Double(fewest) / units)
}
