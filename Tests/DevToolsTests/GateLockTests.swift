import Foundation
import Testing

@testable import DevTools

/// The exclusive gate lock: a second `vmr check` on a checkout fails at once and names the first.
struct GateLockTests {
    private func fixture(_ body: (URL) async throws -> Void) async throws {
        try await withTemporaryDirectory { directory in
            try write(DocsFixture.passing, to: directory)
            try await body(directory)
        }
    }

    private func check(_ steps: [String], in directory: URL) async throws -> Invocation {
        try await VMR.vmr(["check"] + steps + ["--root", directory.path], in: directory)
    }

    @Test
    func aSecondGateFailsAtOnceNamingTheHolderAndSucceedsAfterRelease() async throws {
        try await fixture { directory in
            // This process holds the lock, as a first `vmr check` would; the second one is the real binary.
            let refused = try await GateLock.hold(root: directory) { try await check(["docs"], in: directory) }
            #expect(refused.status == GateLock.busyStatus, "\(refused.combined)")
            #expect(
                refused.error.contains("error: another `vmr check` is already running on this checkout (pid \(getpid()))"),
                "\(refused.error)")
            #expect(!refused.output.contains("==> docs"), "no step may start while the lock is held elsewhere")

            let after = try await check(["docs"], in: directory)
            #expect(after.status == 0, "the lock is free again once the holder is done: \(after.combined)")
        }
    }

    @Test
    func listingTheStepsNeedsNoLock() async throws {
        try await fixture { directory in
            let run = try await GateLock.hold(root: directory) { try await check(["--list"], in: directory) }
            #expect(run.status == 0, "\(run.combined)")
        }
    }

    @Test
    func theLockSurvivesCleaningTheBuildDirectory() async throws {
        try await fixture { directory in
            try await GateLock.hold(root: directory) {
                // `swift package clean` empties .build, the holder's pid file included.
                let build = directory.appending(path: ".build")
                for name in try FileManager.default.contentsOfDirectory(atPath: build.path) {
                    try FileManager.default.removeItem(at: build.appending(path: name))
                }
                let refused = try await check(["docs"], in: directory)
                #expect(refused.status == GateLock.busyStatus, "\(refused.combined)")
                #expect(refused.error.contains("(pid unknown)"), "without its pid file the holder is unknown: \(refused.error)")
            }
        }
    }

    @Test
    func theLockIsExclusiveAndReleasedWhenTheBodyEnds() async throws {
        try await fixture { directory in
            try await GateLock.hold(root: directory) {
                _ = await #expect(throws: ToolError.self) { try await GateLock.hold(root: directory) {} }
            }
            // Another test's `posix_spawn` can still carry a copy of the closed descriptor for a moment (it is
            // close-on-exec), and `flock` is held until every copy is closed: retry briefly instead of failing.
            try await retryingWhileBusy { try await GateLock.hold(root: directory) {} }
        }
    }

    private func retryingWhileBusy(attempts: Int = 100, _ body: () async throws -> Void) async throws {
        for _ in 1..<attempts {
            do { return try await body() } catch let error as ToolError where error.status == GateLock.busyStatus {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await body()
    }
}
