import Foundation
import Testing

@testable import GuestConsole

/// A session on a real socket, through a real bridge, to a fake guest that behaves like a getty and a shell on a terminal.
struct ConsoleEndToEndTests {
    private static let commands: @Sendable (String) -> (output: String, status: Int) = { command in
        switch command {
        case "uname -a": ("Linux localhost 6.12.0-virt #1-Alpine aarch64 Linux\n", 0)
        case "false": ("", 1)
        case "big": ((0..<20_000).map { "line \($0) of a long listing\n" }.joined(), 0)
        default: ("sh: \(command): not found\n", 127)
        }
    }

    private func attach(_ rig: BridgeRig, echo: Bool = true) -> ShellEmulator {
        ShellEmulator(guest: rig.guest, echo: echo, run: Self.commands)
    }

    @Test(.timeLimit(.minutes(1)))
    func aSessionLogsInAndRunsCommandsThroughTheBridge() async throws {
        let rig = try BridgeRig()
        let guest = attach(rig)
        let session = try ConsoleSession.connect(to: rig.scratch.socket)

        #expect(try session.waitForPrompt(timeout: .seconds(20)) == .login)
        try session.login(user: "root", timeout: .seconds(20))
        #expect(
            try session.run("uname -a", timeout: .seconds(20))
                == ExecResult(output: "Linux localhost 6.12.0-virt #1-Alpine aarch64 Linux\n", status: 0))
        #expect(try session.run("false", timeout: .seconds(20)) == ExecResult(output: "", status: 1))
        #expect(try session.run("nosuch", timeout: .seconds(20)) == ExecResult(output: "sh: nosuch: not found\n", status: 127))

        session.close()
        guest.shutdown()
        await rig.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func aTerminalThatDoesNotEchoWorksToo() async throws {
        let rig = try BridgeRig()
        let guest = attach(rig, echo: false)
        let session = try ConsoleSession.connect(to: rig.scratch.socket)
        try session.login(user: "root", timeout: .seconds(20))
        #expect(try session.run("false", timeout: .seconds(20)).status == 1)
        session.close()
        guest.shutdown()
        await rig.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func thirtyCommandsInARowAllSucceed() async throws {
        let rig = try BridgeRig()
        let guest = attach(rig)
        let session = try ConsoleSession.connect(to: rig.scratch.socket)
        try session.login(user: "root", timeout: .seconds(20))
        for round in 0..<30 {
            let result = try session.run(round.isMultiple(of: 2) ? "uname -a" : "false", timeout: .seconds(20))
            #expect(result.status == (round.isMultiple(of: 2) ? 0 : 1), "round \(round)")
        }
        session.close()
        guest.shutdown()
        await rig.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func aLargeOutputArrivesWholeAndInOrder() async throws {
        let rig = try BridgeRig()
        let guest = attach(rig)
        let session = try ConsoleSession.connect(to: rig.scratch.socket)
        try session.login(user: "root", timeout: .seconds(20))
        let result = try session.run("big", timeout: .seconds(30))
        let expected = Self.commands("big").output
        #expect(result.status == 0)
        #expect(result.output.utf8.count == expected.utf8.count)
        #expect(result.output == expected)
        session.close()
        guest.shutdown()
        await rig.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func aSecondSessionIsToldTheConsoleIsBusy() async throws {
        let rig = try BridgeRig()
        let guest = attach(rig)
        let first = try ConsoleSession.connect(to: rig.scratch.socket)
        try first.login(user: "root", timeout: .seconds(20))
        let second = try ConsoleSession.connect(to: rig.scratch.socket)
        #expect(throws: ConsoleError.busy) { try second.waitForPrompt(timeout: .seconds(20)) }
        #expect(try first.run("false", timeout: .seconds(20)).status == 1)
        second.close()
        first.close()
        guest.shutdown()
        await rig.finish()
    }

    @Test(.timeLimit(.minutes(1)))
    func aSessionSeesACleanEndWhenTheGuestSideGoesAway() async throws {
        let rig = try BridgeRig()
        let guest = attach(rig)
        let session = try ConsoleSession.connect(to: rig.scratch.socket)
        try session.login(user: "root", timeout: .seconds(20))
        guest.shutdown()
        rig.guest.close()
        await rig.bridge.waitUntilFinished()
        // The prompt that was already on its way may arrive first; after it the console ends.
        #expect(throws: ConsoleError.self) { try session.run("uname -a", timeout: .seconds(20)) }
        session.close()
        rig.scratch.remove()
    }

    @Test
    func connectingToNothingIsAClearError() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        #expect(throws: ConsoleError.notServed(scratch.socket)) { try ConsoleSession.connect(to: scratch.socket) }
    }

    @Test(.timeLimit(.minutes(1)))
    func theRelayCopiesBothWaysAndStopsAtTheDetachKey() async throws {
        let rig = try BridgeRig()
        let client = try ClientEnd(path: rig.scratch.socket)
        var inputPipe: [Int32] = [-1, -1]
        var outputPipe: [Int32] = [-1, -1]
        #expect(unsafe pipe(&inputPipe) == 0)
        #expect(unsafe pipe(&outputPipe) == 0)
        defer {
            for descriptor in inputPipe + outputPipe { ConsoleSocket.close(descriptor) }
        }

        rig.guest.send("from the guest")
        // The guest's output is on the client socket before the person types, so the relay finds both ready.
        #expect(ConsoleSocket.wait(client.descriptor, milliseconds: 10_000))
        _ = Array("typed\u{1D}ignored".utf8).withUnsafeBytes { unsafe Darwin.write(inputPipe[1], $0.baseAddress, $0.count) }
        let ending = try ConsoleRelay.run(console: client.descriptor, input: inputPipe[0], output: outputPipe[1])
        #expect(ending == .detached)
        var buffer = [UInt8](repeating: 0, count: 256)
        guard case .transferred(let count) = ConsoleSocket.read(outputPipe[0], into: &buffer) else {
            Issue.record("the relay copied nothing to the output")
            return
        }
        #expect(Array(buffer[0..<count]) == Array("from the guest".utf8))
        #expect(rig.guest.receive(count: 5) == Array("typed".utf8))
        client.close()
        await rig.finish()
    }
}
