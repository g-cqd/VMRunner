import Foundation
import Testing

@testable import GuestConsole

/// The bridge on real sockets with a fake guest. Waits are on I/O (a read that returns when bytes arrive); the time limits are
/// only a guard against a hang.
struct ConsoleBridgeTests {
    // MARK: Data flow

    @Test(.timeLimit(.minutes(1)))
    func bytesFlowBothWaysBetweenTheClientAndTheGuest() async throws {
        let rig = try BridgeRig()
        let client = try ClientEnd(path: rig.scratch.socket)
        try client.send("ls\n")
        #expect(rig.guest.receive(count: 3) == Array("ls\n".utf8))
        rig.guest.send("file\r\n")
        #expect(client.receive(count: 6) == Array("file\r\n".utf8))
        client.close()
        await rig.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func aClientThatArrivesLateIsShownWhatTheGuestPrintedBefore() async throws {
        let rig = try BridgeRig()
        rig.guest.send("boot message\r\nlocalhost login: ")
        let expected = Array("boot message\r\nlocalhost login: ".utf8)
        // The guest's output reaches the bridge on its own thread; reading it through a first client is the rendezvous.
        let first = try ClientEnd(path: rig.scratch.socket)
        #expect(first.receive(count: expected.count) == expected)
        first.close()
        let second = try ClientEnd(path: rig.scratch.socket)
        #expect(second.receive(count: expected.count) == expected)
        second.close()
        await rig.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func aSecondClientIsToldTheConsoleIsBusyAndClosedWhileTheFirstKeepsWorking() async throws {
        let rig = try BridgeRig()
        let first = try ClientEnd(path: rig.scratch.socket)
        let second = try ClientEnd(path: rig.scratch.socket)
        #expect(second.receiveUntilEnd() == Array(ConsoleBridge.busyMessage.utf8))
        try first.send("still here\n")
        #expect(rig.guest.receive(count: 11) == Array("still here\n".utf8))
        rig.guest.send("ok")
        #expect(first.receive(count: 2) == Array("ok".utf8))
        second.close()
        first.close()
        await rig.finish()
        #expect(rig.bridge.statistics.clientsAccepted == 1)
        #expect(rig.bridge.statistics.clientsRefused == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func manyRefusedClientsInARowAreAllToldTheConsoleIsBusy() async throws {
        let rig = try BridgeRig()
        let first = try ClientEnd(path: rig.scratch.socket)
        for _ in 0..<50 {
            let refused = try ClientEnd(path: rig.scratch.socket)
            #expect(refused.receiveUntilEnd() == Array(ConsoleBridge.busyMessage.utf8))
            refused.close()
        }
        try first.send("alive\n")
        #expect(rig.guest.receive(count: 6) == Array("alive\n".utf8))
        first.close()
        await rig.finish()
        #expect(rig.bridge.statistics.clientsRefused == 50)
    }

    @Test(.timeLimit(.minutes(1)))
    func aNewClientCanAttachAfterTheFirstLeftAndSeesWhatItMissed() async throws {
        let rig = try BridgeRig()
        let first = try ClientEnd(path: rig.scratch.socket)
        rig.guest.send("one;")
        #expect(first.receive(count: 4) == Array("one;".utf8))
        first.close()
        rig.guest.send("two;")
        // A second client may have to wait for the bridge to notice the first one left; it is refused until then.
        var second = try ClientEnd(path: rig.scratch.socket)
        var seen = second.receive(count: 8)
        while seen != Array("one;two;".utf8) {
            second.close()
            second = try ClientEnd(path: rig.scratch.socket)
            seen = second.receive(count: 8)
        }
        #expect(seen == Array("one;two;".utf8))
        second.close()
        await rig.finish()
    }

    // MARK: Bounds

    @Test(.timeLimit(.minutes(1)))
    func theReplayKeepsTheLastSixtyFourKilobytesAndTheGuestIsNeverHeldUp() async throws {
        let rig = try BridgeRig()
        let size = ConsoleBridge.replayCapacity
        var written = 0
        var all: [UInt8] = []
        // 1 MiB with nobody connected: every write returns, because the bridge reads whatever the guest prints.
        while written < 1 << 20 {
            let chunk = (0..<4_096).map { UInt8(truncatingIfNeeded: (written + $0) / 7) }
            rig.guest.send(chunk)
            all += chunk
            written += chunk.count
        }
        rig.guest.send("END")
        all += Array("END".utf8)
        let client = try ClientEnd(path: rig.scratch.socket)
        var received: [UInt8] = []
        // The replay ends with the last bytes the guest sent; the bridge may still be reading when the client attaches,
        // in which case the rest follows live.
        while received.suffix(3) != Array("END".utf8) {
            let more = client.receiveSome()
            guard !more.isEmpty else { break }
            received += more
        }
        #expect(received.suffix(3) == Array("END".utf8))
        #expect(received.count <= size + 4 * ConsoleBridge.pairBufferBytes)
        #expect(Array(received.suffix(1_000)) == Array(all.suffix(1_000)))
        client.close()
        await rig.finish()
        #expect(rig.bridge.statistics.guestBytesRead == all.count)
        #expect(rig.bridge.statistics.replayDiscarded >= all.count - size)
    }

    @Test(.timeLimit(.minutes(1)))
    func aClientThatDoesNotReadLosesOldOutputButNeverStallsTheGuest() async throws {
        let rig = try BridgeRig()
        let client = try ClientEnd(path: rig.scratch.socket)
        let total = 8 << 20
        var sent = 0
        while sent < total {
            rig.guest.send([UInt8](repeating: 0x61, count: 16 * 1024))
            sent += 16 * 1024
        }
        rig.guest.send("END")
        // Now the client reads: it gets what the socket buffers and the bridge's bounded queue kept, and the end.
        var received = 0
        var tail: [UInt8] = []
        while tail.suffix(3) != Array("END".utf8) {
            let more = client.receiveSome()
            guard !more.isEmpty else { break }
            received += more.count
            tail = Array((tail + more).suffix(3))
        }
        #expect(tail == Array("END".utf8))
        #expect(received < total, "a client that did not read cannot have been given everything")
        client.close()
        await rig.finish()
        #expect(rig.bridge.statistics.droppedToClient > 0)
        #expect(rig.bridge.statistics.guestBytesRead == total + 3)
    }

    // MARK: Ending

    @Test(.timeLimit(.minutes(1)))
    func whenTheGuestSideClosesTheClientGetsEverythingThenTheEndAndTheSocketIsRemoved() async throws {
        let rig = try BridgeRig()
        let client = try ClientEnd(path: rig.scratch.socket)
        rig.guest.send("goodbye\r\n")
        rig.guest.close()
        #expect(client.receiveUntilEnd() == Array("goodbye\r\n".utf8))
        await rig.bridge.waitUntilFinished()
        #expect(!FileManager.default.fileExists(atPath: rig.scratch.socket))
        #expect(throws: ConsoleError.notServed(rig.scratch.socket)) { try ClientEnd(path: rig.scratch.socket) }
        client.close()
        rig.scratch.remove()
    }

    @Test(.timeLimit(.minutes(1)))
    func stoppingTheBridgeGivesTheClientAnEndAndRemovesTheSocket() async throws {
        let rig = try BridgeRig()
        let client = try ClientEnd(path: rig.scratch.socket)
        rig.bridge.stop()
        #expect(client.receiveUntilEnd().isEmpty)
        await rig.bridge.waitUntilFinished()
        #expect(!FileManager.default.fileExists(atPath: rig.scratch.socket))
        // Stopping again, and waiting again, are harmless.
        rig.bridge.stop()
        await rig.bridge.waitUntilFinished()
        client.close()
        await rig.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func aBridgeThatWasNeverStartedReleasesItsSocketWhenStopped() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let pair = try ConsoleBridge.makeGuestPair()
        let bridge = try ConsoleBridge(guestDescriptor: pair.host, socketPath: scratch.socket)
        #expect(FileManager.default.fileExists(atPath: scratch.socket))
        bridge.stop()
        await bridge.waitUntilFinished()
        #expect(!FileManager.default.fileExists(atPath: scratch.socket))
        ConsoleSocket.close(pair.guest)
    }

    // MARK: The socket

    @Test(.timeLimit(.minutes(1)))
    func theSocketIsPrivateToTheUser() async throws {
        let rig = try BridgeRig()
        var status = stat()
        #expect(unsafe lstat(rig.scratch.socket, &status) == 0)
        #expect(status.st_mode & S_IFMT == S_IFSOCK)
        #expect(status.st_mode & 0o777 == 0o600)
        #expect(status.st_uid == geteuid())
        await rig.finish()
    }

    @Test
    func aPathLongerThanASocketPathIsRefused() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let pair = try ConsoleBridge.makeGuestPair()
        defer {
            ConsoleSocket.close(pair.host)
            ConsoleSocket.close(pair.guest)
        }
        let long = scratch.path + "/" + String(repeating: "x", count: 120) + ".sock"
        #expect(throws: ConsoleError.pathTooLong(path: long, limit: ConsoleSocket.pathLimit)) {
            try ConsoleBridge(guestDescriptor: pair.host, socketPath: long)
        }
    }

    @Test
    func theLongestPathThatFitsIsAccepted() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let pair = try ConsoleBridge.makeGuestPair()
        defer { ConsoleSocket.close(pair.guest) }
        let fitting = scratch.path + "/" + String(repeating: "y", count: ConsoleSocket.pathLimit - scratch.path.utf8.count - 1)
        #expect(fitting.utf8.count == ConsoleSocket.pathLimit)
        let bridge = try ConsoleBridge(guestDescriptor: pair.host, socketPath: fitting)
        bridge.stop()
        await bridge.waitUntilFinished()
    }

    @Test
    func aRelativePathIsRefused() throws {
        let pair = try ConsoleBridge.makeGuestPair()
        defer {
            ConsoleSocket.close(pair.host)
            ConsoleSocket.close(pair.guest)
        }
        #expect(throws: ConsoleError.pathNotAbsolute("console.sock")) {
            try ConsoleBridge(guestDescriptor: pair.host, socketPath: "console.sock")
        }
    }

    @Test
    func aFileThatIsNotASocketIsNeverReplaced() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        try Data("precious".utf8).write(to: URL(filePath: scratch.socket))
        let pair = try ConsoleBridge.makeGuestPair()
        defer {
            ConsoleSocket.close(pair.host)
            ConsoleSocket.close(pair.guest)
        }
        #expect(throws: ConsoleError.notASocket(scratch.socket)) {
            try ConsoleBridge(guestDescriptor: pair.host, socketPath: scratch.socket)
        }
        #expect(try String(contentsOf: URL(filePath: scratch.socket), encoding: .utf8) == "precious")
    }

    @Test
    func aStaleSocketOfTheUserIsRemovedAndReplaced() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        // A socket nobody listens on any more: bound, then closed without unlinking.
        let leftover = try ConsoleSocket.listen(at: scratch.socket)
        ConsoleSocket.close(leftover.descriptor)
        #expect(FileManager.default.fileExists(atPath: scratch.socket))

        let pair = try ConsoleBridge.makeGuestPair()
        let bridge = try ConsoleBridge(guestDescriptor: pair.host, socketPath: scratch.socket)
        bridge.start()
        let client = try ClientEnd(path: scratch.socket)
        client.close()
        bridge.stop()
        await bridge.waitUntilFinished()
        ConsoleSocket.close(pair.guest)
    }

    @Test
    func aSocketAnotherProcessIsServingIsNotTakenOver() async throws {
        let rig = try BridgeRig()
        let pair = try ConsoleBridge.makeGuestPair()
        defer {
            ConsoleSocket.close(pair.host)
            ConsoleSocket.close(pair.guest)
        }
        #expect(throws: ConsoleError.socketInUse(rig.scratch.socket)) {
            try ConsoleBridge(guestDescriptor: pair.host, socketPath: rig.scratch.socket)
        }
        await rig.finish()
    }

    @Test
    func aDirectoryOthersCanEnterIsRefused() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.path)
        let pair = try ConsoleBridge.makeGuestPair()
        defer {
            ConsoleSocket.close(pair.host)
            ConsoleSocket.close(pair.guest)
        }
        #expect(throws: ConsoleError.self) { try ConsoleBridge(guestDescriptor: pair.host, socketPath: scratch.socket) }
        #expect(!FileManager.default.fileExists(atPath: scratch.socket))
    }

    @Test
    func aPrivateDirectoryIsCreatedWithTheRightModeAndAnOpenOneIsNotChanged() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let made = scratch.path + "/inner"
        try ConsoleBridge.makePrivateDirectory(at: made)
        let mode = try FileManager.default.attributesOfItem(atPath: made)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: made)
        #expect(throws: ConsoleError.self) { try ConsoleBridge.makePrivateDirectory(at: made) }
        let unchanged = try FileManager.default.attributesOfItem(atPath: made)[.posixPermissions] as? Int
        #expect(unchanged == 0o750)
    }
}
