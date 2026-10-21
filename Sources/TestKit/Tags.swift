// `public import`: this file extends Swift Testing's `Tag` with a public static member.
public import Testing

extension Tag {
    /// Concurrency and async-coordination suites, so a CI lane can select or exclude them.
    @Tag public static var concurrency: Self

    /// Benchmarks: they measure and record instead of asserting, and run only when a results file is named
    /// (``benchmarkResultsPath``), so the default test run skips them. Put it next to `.benchmarksRequested`.
    @Tag public static var bench: Self
}
