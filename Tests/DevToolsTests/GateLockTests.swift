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
            // `hold` unlocks before it closes, so the lock is free at once even while a concurrent spawn still holds a copy
            // of the descriptor (see the next test).
            try await GateLock.hold(root: directory) {}
        }
    }

    /// Why `hold` unlocks before it closes: `flock` belongs to the open file, so a copy of the descriptor (the one a concurrent
    /// spawn holds until its exec closes it) keeps the lock after a `close`, and only an explicit unlock releases it at once.
    /// The second half runs `GateLock.release`, the function `hold` ends with, while a copy of the descriptor stays open.
    @Test
    func anExplicitUnlockReleasesTheLockWhileACopyOfTheDescriptorIsStillOpen() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "gate-lock-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = unsafe open(directory.path, O_RDONLY | O_CLOEXEC)
        try #require(other >= 0)
        defer { close(other) }

        let closedOnly = unsafe open(directory.path, O_RDONLY | O_CLOEXEC)
        try #require(closedOnly >= 0 && flock(closedOnly, LOCK_EX | LOCK_NB) == 0)
        let firstCopy = dup(closedOnly)
        close(closedOnly)
        #expect(flock(other, LOCK_EX | LOCK_NB) != 0, "a close leaves the lock with the copy")
        close(firstCopy)
        #expect(flock(other, LOCK_EX | LOCK_NB) == 0, "the last copy's close releases it")
        #expect(flock(other, LOCK_UN) == 0)

        let held = unsafe open(directory.path, O_RDONLY | O_CLOEXEC)
        try #require(held >= 0 && flock(held, LOCK_EX | LOCK_NB) == 0)
        let secondCopy = dup(held)
        defer { close(secondCopy) }
        GateLock.release(held)
        let second = unsafe open(directory.path, O_RDONLY | O_CLOEXEC)
        try #require(second >= 0)
        defer { close(second) }
        #expect(flock(second, LOCK_EX | LOCK_NB) == 0, "GateLock.release frees the lock whatever copies remain")
    }
}
