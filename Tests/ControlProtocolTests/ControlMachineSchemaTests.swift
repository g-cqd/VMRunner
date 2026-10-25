import Foundation
import Testing

@testable import ControlProtocol

/// The shape of a machine in the service's answers: `workload` was added after the other members, so old and new meet.
struct ControlMachineSchemaTests {
    private let id = UUID()

    private func json(_ machine: ControlMachine) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let object = try JSONSerialization.jsonObject(with: encoder.encode(machine))
        return try #require(object as? [String: Any])
    }

    @Test
    func aMachineIsWrittenWithItsWorkloadAndTheMembersItAlwaysHad() throws {
        let box = ControlMachine(id: id, name: "box", guest: "linux", state: .running, agentAccess: true, workload: "container")
        let written = try json(box)
        #expect(Set(written.keys) == ["id", "name", "guest", "state", "agentAccess", "workload"])
        #expect(written["workload"] as? String == "container" && written["guest"] as? String == "linux")
        #expect(
            try json(ControlMachine(id: id, name: "vm", guest: "macOS", state: .stopped, agentAccess: false))["workload"] as? String == "vm"
        )
    }

    @Test
    func anAnswerFromAServiceThatPredatesContainersReadsAsAVirtualMachine() throws {
        let old = #"{"agentAccess":true,"guest":"linux","id":"\#(id.uuidString)","name":"old","state":"stopped"}"#
        let machine = try JSONDecoder().decode(ControlMachine.self, from: Data(old.utf8))
        #expect(machine == ControlMachine(id: id, name: "old", guest: "linux", state: .stopped, agentAccess: true, workload: "vm"))
    }

    @Test
    func aMemberANewerServiceAddsIsIgnored() throws {
        let newer =
            #"{"agentAccess":false,"extra":{"a":1},"guest":"macOS","id":"\#(id.uuidString)","name":"n","state":"paused","workload":"vm"}"#
        let machine = try JSONDecoder().decode(ControlMachine.self, from: Data(newer.utf8))
        #expect(machine.state == .paused && machine.workload == "vm")
    }

    @Test
    func theWorkloadMakesTheListNoDeeperThanTheClientReads() throws {
        let box = ControlMachine(id: id, name: "box", guest: "linux", state: .running, agentAccess: true, workload: "container")
        let encoder = JSONEncoder()
        let line = Data(#"{"id":1,"jsonrpc":"2.0","result":{"machines":"#.utf8) + (try encoder.encode([box])) + Data("}}".utf8)
        #expect(RPCMessage.nesting(of: line) == 4)
        #expect(RPCMessage.nesting(of: line) <= ControlAnswer.deepestNesting)
    }
}
