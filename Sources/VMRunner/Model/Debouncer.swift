import Foundation

/// Runs `action` with the newest value once `quietPeriod` has passed without another `submit`; earlier values are
/// dropped. Time comes from the injected `Clock`, so a test clock decides when it fires.
@MainActor
final class Debouncer<Value> {
    private let quietPeriod: Duration
    private let sleep: (Duration) async throws -> Void
    private let action: @MainActor (Value) -> Void
    private var pending: Task<Void, Never>?

    init<C: Clock>(quietPeriod: Duration, clock: C, action: @escaping @MainActor (Value) -> Void) where C.Duration == Duration {
        self.quietPeriod = quietPeriod
        self.action = action
        sleep = { try await clock.sleep(for: $0) }
    }

    isolated deinit { pending?.cancel() }

    func submit(_ value: Value) {
        pending?.cancel()
        pending = Task { [quietPeriod, sleep, action] in
            try? await sleep(quietPeriod)
            guard !Task.isCancelled else { return }
            action(value)
        }
    }
}

/// Waits until `condition` holds, checking it every `interval` for at most `attempts` sleeps, then gives up quietly.
@MainActor
func poll<C: Clock>(every interval: Duration, attempts: Int, clock: C, until condition: () -> Bool) async where C.Duration == Duration {
    for _ in 0..<attempts where !condition() { try? await clock.sleep(for: interval) }
}
