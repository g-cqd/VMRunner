import ControlProtocol
import Foundation
import Testing

@testable import DevTools

/// The real `vmr control mcp` with a session piped into it, against the library's own service under `/tmp`.
struct ControlMCPCommandTests {
    @Test
    func anAgentListsAndStartsAMachineThroughTheMCPServer() async throws {
        let machine = ControlMachine(id: UUID(), name: "agent", guest: "linux", state: .stopped, agentAccess: true)
        let fixture = try ControlFixture.start(machines: [machine])
        do {
            let messages = [
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}"#,
                #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"machines_list"}}"#,
                #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"machines_start","#
                    + #""arguments":{"machine":"\#(machine.id.uuidString)"}}}"#,
            ]
            // `sh -c SCRIPT vmr m1 m2 m3 m4 socket`: the messages are piped in, one per line, and the input then ends.
            let script = #"printf '%s\n' "$1" "$2" "$3" "$4" | "$0" control mcp --socket "$5""#
            let run = try await VMR.run(
                "/bin/sh", ["-c", script, try VMR.binary(named: "vmr").path] + messages + [fixture.socket], in: fixture.folder,
                environment: try fixture.environment([.list, .start]))
            #expect(run.status == 0, "\(run.combined)")
            let answers = try run.output.split(separator: "\n").map {
                try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
            #expect(answers.compactMap { $0["id"] as? Int } == [1, 2, 3], "one answer per request, none for the notification")
            let started = try #require(answers.last?["result"] as? [String: Any])
            #expect(started["isError"] as? Bool == false)
            let text = try #require((started["content"] as? [[String: Any]])?.first?["text"] as? String)
            #expect(text == #"{"id":"\#(machine.id.uuidString)","state":"running"}"#)
            #expect(fixture.machines.requests == ["start \(machine.id.uuidString)"])
        } catch {
            await fixture.stop()
            throw error
        }
        await fixture.stop()
    }

    @Test
    func withoutATokenTheServerDoesNotStartAndWritesNothingToItsOutput() async throws {
        try await withTemporaryDirectory { directory in
            let run = try await VMR.vmr(["control", "mcp", "--socket", "/tmp/vmr-no-such-control.sock"], in: directory)
            #expect(run.status == 64, "\(run.combined)")
            #expect(run.output.isEmpty)
            #expect(run.error.contains("no token"), "\(run.error)")
        }
    }
}
