import ControlProtocol
import Foundation
import Testing

@testable import DevTools

/// `vmr control log` against the library's own service on a socket under `/tmp`, with machines held in memory. Each test stops
/// its service before it returns.
struct ControlLogCommandTests {
    private let alpha = ControlMachine(id: UUID(), name: "alpha", guest: "linux", state: .running, agentAccess: true, workload: "container")

    /// Runs `body` against a service on alpha, then stops the service whatever happened.
    private func withService(_ body: (ControlFixture) async throws -> Void) async throws {
        let fixture = try ControlFixture.start(machines: [alpha])
        do {
            try await body(fixture)
        } catch {
            await fixture.stop()
            throw error
        }
        await fixture.stop()
    }

    @Test
    func logPrintsTheTextOfTheMachinesLog() async throws {
        try await withService { fixture in
            let run = try await VMR.vmr(
                ["control", "log", "alpha", "--socket", fixture.socket], in: fixture.folder,
                environment: try fixture.environment([.list, .log]))
            #expect(run.status == 0, "\(run.combined)")
            #expect(run.output == MemoryMachines.logText)
            #expect(fixture.machines.requests == ["log \(alpha.id.uuidString)"])
        }
    }

    @Test
    func bytesKeepsTheEndAndSaysThatEarlierOutputIsNotShown() async throws {
        try await withService { fixture in
            let run = try await VMR.vmr(
                ["control", "log", alpha.id.uuidString, "--bytes", "5", "--socket", fixture.socket], in: fixture.folder,
                environment: try fixture.environment([.log]))
            #expect(run.status == 0, "\(run.combined)")
            #expect(run.output == "[earlier output not shown]\n two\n")
        }
    }

    @Test
    func aWholeLogThatFitsHasNoNotice() async throws {
        try await withService { fixture in
            let run = try await VMR.vmr(
                ["control", "log", alpha.id.uuidString, "--bytes", "65536", "--socket", fixture.socket], in: fixture.folder,
                environment: try fixture.environment([.log]))
            #expect(run.status == 0, "\(run.combined)")
            #expect(!run.output.contains("not shown"))
        }
    }

    @Test(arguments: ["0", "65537", "-1", "many"])
    func aSizeOutsideOneTo65536IsAUsageError(bytes: String) async throws {
        try await withService { fixture in
            let run = try await VMR.vmr(
                ["control", "log", alpha.id.uuidString, "--bytes=\(bytes)", "--socket", fixture.socket], in: fixture.folder,
                environment: try fixture.environment([.log]))
            #expect(run.status == 64, "\(run.combined)")
            #expect(fixture.machines.requests.isEmpty, "nothing was asked of the service")
        }
    }

    @Test
    func jsonPrintsTheServicesAnswer() async throws {
        try await withService { fixture in
            let run = try await VMR.vmr(
                ["control", "log", alpha.id.uuidString, "--json", "--socket", fixture.socket], in: fixture.folder,
                environment: try fixture.environment([.log]))
            #expect(run.status == 0, "\(run.combined)")
            let log = try JSONDecoder().decode(ControlLog.self, from: Data(run.output.utf8))
            #expect(log == ControlLog(id: alpha.id, text: MemoryMachines.logText, truncated: false))
        }
    }

    @Test
    func aSizeWithJSONIsAUsageErrorBecauseJSONPrintsTheServicesAnswer() async throws {
        try await withService { fixture in
            let run = try await VMR.vmr(
                ["control", "log", alpha.id.uuidString, "--json", "--bytes", "5", "--socket", fixture.socket], in: fixture.folder,
                environment: try fixture.environment([.log]))
            #expect(run.status == 64, "\(run.combined)")
            #expect(run.error.contains("--bytes does not apply to --json"), "\(run.error)")
            #expect(fixture.machines.requests.isEmpty)
        }
    }

    @Test
    func aTokenWithoutTheLogCapabilityExits77() async throws {
        try await withService { fixture in
            let run = try await VMR.vmr(
                ["control", "log", alpha.id.uuidString, "--socket", fixture.socket], in: fixture.folder,
                environment: try fixture.environment([.list, .state]))
            #expect(run.status == 77, "\(run.combined)")
            #expect(run.error.contains("Not permitted (-32001)"), "\(run.error)")
            #expect(fixture.machines.requests.isEmpty)
        }
    }
}
