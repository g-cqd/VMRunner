import ControlProtocol
import Foundation
import Testing

@testable import DevTools

/// The real `vmr control` binary against the library's own service on a socket under `/tmp`, with machines held in memory.
/// Each test stops its service in a `defer`-like `stop()` before it returns.
struct ControlMachineCommandTests {
    private let alpha = ControlMachine(id: UUID(), name: "alpha", guest: "linux", state: .running, agentAccess: true)
    private let beta = ControlMachine(id: UUID(), name: "beta", guest: "macOS", state: .stopped, agentAccess: false)

    /// Runs `body` against a service on alpha and beta, then stops the service whatever happened.
    private func withService(_ body: (ControlFixture) async throws -> Void) async throws {
        let fixture = try ControlFixture.start(machines: [alpha, beta])
        do {
            try await body(fixture)
        } catch {
            await fixture.stop()
            throw error
        }
        await fixture.stop()
    }

    @Test
    func listPrintsOnlyTheMachinesWithAgentAccess() async throws {
        try await withService { fixture in
            let run = try await VMR.vmr(
                ["control", "list", "--socket", fixture.socket], in: fixture.folder, environment: try fixture.environment([.list]))
            #expect(run.status == 0, "\(run.combined)")
            #expect(run.output == "\(alpha.id.uuidString)  running       linux  alpha\n")
        }
    }

    @Test
    func listWithJSONPrintsTheServicesAnswer() async throws {
        try await withService { fixture in
            let run = try await VMR.vmr(
                ["control", "list", "--socket", fixture.socket, "--json"], in: fixture.folder,
                environment: try fixture.environment([.list]))
            #expect(run.status == 0, "\(run.combined)")
            let list = try JSONDecoder().decode([String: [ControlMachine]].self, from: Data(run.output.utf8))
            #expect(list["machines"] == [alpha])
        }
    }

    @Test
    func stateTakesAMachinesNameOrItsID() async throws {
        try await withService { fixture in
            let environment = try fixture.environment([.list, .state])
            let byName = try await VMR.vmr(
                ["control", "state", "alpha", "--socket", fixture.socket], in: fixture.folder, environment: environment)
            #expect(byName.status == 0, "\(byName.combined)")
            #expect(byName.output == "alpha (\(alpha.id.uuidString)): running\n")
            let byID = try await VMR.vmr(
                ["control", "state", alpha.id.uuidString, "--socket", fixture.socket, "--json"], in: fixture.folder,
                environment: environment)
            #expect(byID.status == 0, "\(byID.combined)")
            #expect(try JSONDecoder().decode(ControlMachine.self, from: Data(byID.output.utf8)) == alpha)
        }
    }

    @Test
    func aNameNoMachineWithAgentAccessHasExits1() async throws {
        try await withService { fixture in
            let run = try await VMR.vmr(
                ["control", "state", "beta", "--socket", fixture.socket], in: fixture.folder,
                environment: try fixture.environment([.list, .state]))
            #expect(run.status == 1, "\(run.combined)")
            #expect(run.error.contains("no machine named beta has agent access"), "\(run.error)")
        }
    }

    @Test
    func aTokenWithoutTheCapabilityExits77() async throws {
        try await withService { fixture in
            let run = try await VMR.vmr(
                ["control", "list", "--socket", fixture.socket, "--json"], in: fixture.folder,
                environment: try fixture.environment([.state]))
            #expect(run.status == 77, "\(run.combined)")
            #expect(run.error.contains("Not permitted (-32001)"), "\(run.error)")
            #expect(run.output == #"{"error":{"code":-32001,"message":"Not permitted"}}"# + "\n")
        }
    }

    @Test
    func aCallWithoutATokenIsAUsageError() async throws {
        try await withService { fixture in
            let run = try await VMR.vmr(["control", "list", "--socket", fixture.socket], in: fixture.folder)
            #expect(run.status == 64, "\(run.combined)")
            #expect(run.error.contains("no token"), "\(run.error)")
        }
    }

    @Test
    func statusChecksTheTokenAgainstALiveService() async throws {
        try await withService { fixture in
            let run = try await VMR.vmr(
                ["control", "status", "--socket", fixture.socket], in: fixture.folder, environment: try fixture.environment([.list]))
            #expect(run.status == 0, "\(run.combined)")
            #expect(run.output.contains("listening at \(fixture.socket)"), "\(run.output)")
            #expect(run.output.contains("the token is accepted: it lists 1 machine(s)"), "\(run.output)")
            let refused = try await VMR.vmr(
                ["control", "status", "--socket", fixture.socket], in: fixture.folder, environment: try fixture.environment([.start]))
            #expect(refused.status == 77, "\(refused.combined)")
            #expect(refused.output.contains("the token is refused: Not permitted (-32001)"), "\(refused.output)")
        }
    }

    @Test
    func aPrivateTokenFileIsRead() async throws {
        try await withService { fixture in
            let file = fixture.folder.appending(path: "token")
            let secret = try fixture.store.create(name: "file", capabilities: [.list]).secret
            try Data((secret + "\n").utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let run = try await VMR.vmr(["control", "list", "--socket", fixture.socket, "--token-file", file.path], in: fixture.folder)
            #expect(run.status == 0, "\(run.combined)")
            #expect(run.output.contains("alpha"))
        }
    }

    @Test
    func startByNameAnswersOnceTheMachineRuns() async throws {
        try await withService { fixture in
            let run = try await VMR.vmr(
                ["control", "start", "alpha", "--socket", fixture.socket], in: fixture.folder,
                environment: try fixture.environment([.list, .start]))
            #expect(run.status == 0, "\(run.combined)")
            #expect(run.output == "\(alpha.id.uuidString): running\n")
            #expect(fixture.machines.requests == ["start \(alpha.id.uuidString)"])
        }
    }

    @Test
    func screenshotWritesThePNGToTheFileForItsOwnerOnly() async throws {
        try await withService { fixture in
            let environment = try fixture.environment([.screen])
            let run = try await VMR.vmr(
                ["control", "screenshot", alpha.id.uuidString, "--output", "shot.png", "--socket", fixture.socket],
                in: fixture.folder, environment: environment)
            #expect(run.status == 0, "\(run.combined)")
            #expect(run.output == "\(alpha.id.uuidString): 4 x 3 png, 6 bytes, written to shot.png\n")
            let file = fixture.folder.appending(path: "shot.png")
            #expect(try Data(contentsOf: file) == MemoryMachines.picture)
            #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
            #expect(fixture.machines.requests == ["screenshot \(alpha.id.uuidString)"])

            let json = try await VMR.vmr(
                ["control", "screenshot", alpha.id.uuidString, "--json", "--socket", fixture.socket], in: fixture.folder,
                environment: environment)
            #expect(json.status == 0, "\(json.combined)")
            let shot = try JSONDecoder().decode(ControlScreenshot.self, from: Data(json.output.utf8))
            #expect(shot.data == MemoryMachines.picture && shot.format == "png")
        }
    }

    @Test
    func aScreenshotIsWrittenToANewFileForItsOwnerAndAnExistingPathIsRefused() async throws {
        try await withTemporaryDirectory { folder in
            let png = Data([0x89, 0x50, 0x4E, 0x47])
            let answer = try JSONEncoder().encode(ControlScreenshot(id: alpha.id, width: 4, height: 3, png: png))
            let path = folder.appending(path: "shot.png").path

            _ = try ControlInvocation.save(screenshot: answer, to: path)

            #expect(try Data(contentsOf: URL(filePath: path)) == png)
            #expect(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o600)
            #expect(throws: ToolError.self) { try ControlInvocation.save(screenshot: answer, to: path) }
            #expect(try Data(contentsOf: URL(filePath: path)) == png)
        }
    }

    @Test
    func screenshotNeedsAFileOrJSONButNotBothAndTheScreenCapability() async throws {
        try await withService { fixture in
            let environment = try fixture.environment([.screen])
            let neither = try await VMR.vmr(
                ["control", "screenshot", alpha.id.uuidString, "--socket", fixture.socket], in: fixture.folder, environment: environment)
            #expect(neither.status == 64, "\(neither.combined)")
            let both = try await VMR.vmr(
                ["control", "screenshot", alpha.id.uuidString, "--json", "-o", "x.png", "--socket", fixture.socket],
                in: fixture.folder, environment: environment)
            #expect(both.status == 64, "\(both.combined)")
            let lacking = try await VMR.vmr(
                ["control", "screenshot", alpha.id.uuidString, "-o", "x.png", "--socket", fixture.socket], in: fixture.folder,
                environment: try fixture.environment([.state]))
            #expect(lacking.status == 77, "\(lacking.combined)")
            #expect(!FileManager.default.fileExists(atPath: fixture.folder.appending(path: "x.png").path))
            #expect(fixture.machines.requests.isEmpty)
        }
    }

    @Test
    func stopAsksTheGuestAndForceCutsThePower() async throws {
        try await withService { fixture in
            let environment = try fixture.environment([.stop])
            let polite = try await VMR.vmr(
                ["control", "stop", alpha.id.uuidString, "--socket", fixture.socket], in: fixture.folder, environment: environment)
            #expect(polite.status == 0, "\(polite.combined)")
            #expect(polite.output == "\(alpha.id.uuidString): shuttingDown\n")
            let forced = try await VMR.vmr(
                ["control", "stop", alpha.id.uuidString, "--force", "--json", "--socket", fixture.socket], in: fixture.folder,
                environment: environment)
            #expect(forced.status == 0, "\(forced.combined)")
            #expect(forced.output == #"{"id":"\#(alpha.id.uuidString)","state":"stopped"}"# + "\n")
            #expect(fixture.machines.requests == ["stop \(alpha.id.uuidString)", "stop \(alpha.id.uuidString) force"])
        }
    }

    @Test
    func aMachineWhoseAgentAccessIsOffIsNotStarted() async throws {
        try await withService { fixture in
            let run = try await VMR.vmr(
                ["control", "start", beta.id.uuidString, "--socket", fixture.socket], in: fixture.folder,
                environment: try fixture.environment([.start]))
            #expect(run.status == 1, "\(run.combined)")
            #expect(run.error.contains("Agent access is off for this machine (-32003)"), "\(run.error)")
            #expect(fixture.machines.requests.isEmpty)
        }
    }

    @Test
    func aStartWithoutTheCapabilityExits77AndStartsNothing() async throws {
        try await withService { fixture in
            let run = try await VMR.vmr(
                ["control", "start", alpha.id.uuidString, "--socket", fixture.socket], in: fixture.folder,
                environment: try fixture.environment([.list, .state, .stop]))
            #expect(run.status == 77, "\(run.combined)")
            #expect(fixture.machines.requests.isEmpty)
        }
    }
}
