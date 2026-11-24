/// Pure polling/timeout policy; the display adapter supplies an injected clock and never waits in tests.
struct WindowsDisplayTiming {
    private var nextMetadata = Duration.zero
    private var lastRecord = Duration.zero

    func needsMetadata(at elapsed: Duration) -> Bool { elapsed >= nextMetadata }

    mutating func readMetadata(at elapsed: Duration) { nextMetadata = elapsed + .seconds(1) }

    mutating func mappedFrame(at elapsed: Duration) { lastRecord = elapsed }

    func timedOut(at elapsed: Duration) -> Bool { elapsed - lastRecord >= .seconds(60) }
}
