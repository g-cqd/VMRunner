import Foundation
import TestKit
import Testing

@testable import ControlProtocol

/// The checks every request passes (a token, its capability, its machines, the machine's agent access) and what each method
/// answers. Refusals are reported, and never with a token.
struct ControlDispatcherTests {
    /// A dispatcher over fake machines and a store in a scratch folder, with the refusals it reported.
    struct Rig {
        let folder: ScratchFolder
        let store: ControlTokenStore
        let machines: FakeMachines
        let denials: AsyncEventProbe<ControlDenial>
        let dispatcher: ControlDispatcher

        init(
            _ list: [ControlMachine], startOutcome: ControlOutcome = .done(.running),
            screenshotOutcome: ControlScreenshotOutcome? = nil
        ) throws {
            folder = try ScratchFolder()
            store = try ControlTokenStore(file: folder.url.appending(path: "tokens.json"))
            machines = FakeMachines(list, startOutcome: startOutcome, screenshotOutcome: screenshotOutcome)
            let probe = AsyncEventProbe<ControlDenial>()
            denials = probe
            dispatcher = ControlDispatcher(tokens: store, machines: machines, report: { probe.record($0) })
        }

        func secret(_ capabilities: Set<ControlCapability> = Set(ControlCapability.allCases), machines: [UUID]? = nil) throws
            -> String
        {
            try store.create(name: "test", capabilities: capabilities, machines: machines).secret
        }

        func call(_ method: String, _ params: [String: RPCValue]) async -> RPCResponse {
            await dispatcher.answer(RPCRequest(id: .number(1), method: method, params: params))
        }
    }

    private func object(_ response: RPCResponse) throws -> [String: Any] {
        guard case .result(let json) = response.body else {
            Issue.record("expected a result, got \(response)")
            return [:]
        }
        return try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
    }

    private func names(_ response: RPCResponse) throws -> [String] {
        (try object(response)["machines"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    @Test
    func eachMethodNeedsItsOwnCapability() async throws {
        let machine = ControlMachine.fake("m")
        let rig = try Rig([machine])
        defer { rig.folder.cleanUp() }
        for method in ControlMethod.allCases {
            let lacking = try rig.secret(Set(ControlCapability.allCases).subtracting([method.capability]))
            let holding = try rig.secret([method.capability])
            var params: [String: RPCValue] = method == .list ? [:] : ["machine": .string(machine.id.uuidString)]
            params["token"] = .string(lacking)
            #expect(await rig.call(method.rawValue, params).error?.code == -32001, "\(method) without its capability")
            params["token"] = .string(holding)
            #expect(await rig.call(method.rawValue, params).error == nil, "\(method) with its capability")
        }
        #expect(rig.denials.events.count == ControlMethod.allCases.count)
        #expect(rig.denials.events.allSatisfy { $0.reason == .missingCapability && $0.tokenID != nil })
    }

    @Test
    func noTokenAnUnknownOneAndARevokedOneAreRefusedAndReported() async throws {
        let rig = try Rig([.fake("m")])
        defer { rig.folder.cleanUp() }
        let made = try rig.store.create(name: "gone", capabilities: [.list])
        try rig.store.revoke(made.token.id)

        #expect(await rig.call("machines.list", [:]).error?.code == -32001)
        #expect(await rig.call("machines.list", ["token": .string(ControlSecret.make())]).error?.code == -32001)
        #expect(await rig.call("machines.list", ["token": .string(made.secret)]).error?.code == -32001)
        #expect(rig.denials.events.map(\.reason) == [.noToken, .unknownToken, .unknownToken])
        #expect(rig.denials.events.allSatisfy { $0.tokenID == nil && $0.method == .list })
    }

    @Test
    func aTokenLimitedToSomeMachinesSeesAndActsOnThoseOnly() async throws {
        let mine = ControlMachine.fake("mine")
        let other = ControlMachine.fake("other")
        let rig = try Rig([mine, other])
        defer { rig.folder.cleanUp() }
        let secret = try rig.secret(machines: [mine.id])

        let listed = await rig.call("machines.list", ["token": .string(secret)])
        #expect(try names(listed) == ["mine"])
        #expect(await rig.call("machines.state", ["token": .string(secret), "machine": .string(mine.id.uuidString)]).error == nil)
        let refused = await rig.call("machines.start", ["token": .string(secret), "machine": .string(other.id.uuidString)])
        #expect(refused.error?.code == -32001)
        #expect(rig.denials.events.map(\.reason) == [.outsideScope])
        #expect(rig.machines.calls.events.isEmpty, "nothing was started")
    }

    @Test
    func aMachineWithAgentAccessOffIsLeftOutOfTheListAndRefused() async throws {
        let closed = ControlMachine.fake("closed", access: false)
        let open = ControlMachine.fake("open")
        let rig = try Rig([closed, open])
        defer { rig.folder.cleanUp() }
        let secret = try rig.secret()

        let listed = await rig.call("machines.list", ["token": .string(secret)])
        #expect(try names(listed) == ["open"])
        let refused = await rig.call("machines.start", ["token": .string(secret), "machine": .string(closed.id.uuidString)])
        #expect(refused.error?.code == -32003)
        #expect(rig.denials.events.map(\.reason) == [.agentAccessOff])
        #expect(rig.machines.calls.events.isEmpty, "nothing was started")
        let unknown = await rig.call("machines.state", ["token": .string(secret), "machine": .string(UUID().uuidString)])
        #expect(unknown.error?.code == -32002)
    }

    @Test
    func malformedParamsAndUnknownMethodsAreRefusedBeforeAnyTokenIsLookedAt() async throws {
        let machine = ControlMachine.fake("m")
        let rig = try Rig([machine])
        defer { rig.folder.cleanUp() }
        let secret = try rig.secret()
        let id = machine.id.uuidString
        #expect(await rig.call("machines.state", ["token": .string(secret)]).error?.code == -32602, "no machine")
        #expect(await rig.call("machines.state", ["token": .string(secret), "machine": .string("nope")]).error?.code == -32602)
        #expect(await rig.call("machines.list", ["token": .string(secret), "verbose": .bool(true)]).error?.code == -32602)
        #expect(
            await rig.call("machines.stop", ["token": .string(secret), "machine": .string(id), "force": .string("yes")]).error?
                .code == -32602)
        #expect(await rig.call("machines.list", ["token": .bool(true)]).error?.code == -32602)
        #expect(await rig.call("machines.delete", ["token": .string(secret)]).error?.code == -32601)
        #expect(await rig.call("rpc.discover", [:]).error?.code == -32601)
        #expect(rig.denials.events.isEmpty)
    }

    @Test
    func startAndStopAnswerTheNewStateAndAStopPassesForce() async throws {
        let machine = ControlMachine.fake("m")
        let rig = try Rig([machine])
        defer { rig.folder.cleanUp() }
        let secret = try rig.secret()
        let id = machine.id.uuidString

        let startAnswer = await rig.call("machines.start", ["token": .string(secret), "machine": .string(id)])
        let started = try object(startAnswer)
        #expect(started["state"] as? String == "running")
        #expect(started["id"] as? String == id)
        let forceAnswer = await rig.call("machines.stop", ["token": .string(secret), "machine": .string(id), "force": .bool(true)])
        #expect(try object(forceAnswer)["state"] as? String == "stopped")
        let askAnswer = await rig.call("machines.stop", ["token": .string(secret), "machine": .string(id)])
        #expect(try object(askAnswer)["state"] as? String == "shuttingDown")
        #expect(rig.machines.calls.events == ["start \(id)", "stop \(id) force=true", "stop \(id) force=false"])

        let stateAnswer = await rig.call("machines.state", ["token": .string(secret), "machine": .string(id)])
        let state = try object(stateAnswer)
        #expect(state["name"] as? String == "m")
        #expect(state["state"] as? String == "stopped")
    }

    @Test
    func aScreenshotNeedsTheScreenCapabilityAndAnswersThePictureOfTheMachine() async throws {
        let machine = ControlMachine.fake("m")
        let rig = try Rig([machine])
        defer { rig.folder.cleanUp() }
        let id = machine.id.uuidString
        let without = try rig.secret([.list, .state, .start, .stop])
        let refused = await rig.call("machines.screenshot", ["token": .string(without), "machine": .string(id)])
        #expect(refused.error?.code == -32001)
        #expect(rig.denials.events.map(\.reason) == [.missingCapability])
        #expect(rig.machines.calls.events.isEmpty, "no screenshot was taken")

        let answer = await rig.call("machines.screenshot", ["token": .string(try rig.secret([.screen])), "machine": .string(id)])
        let shot = try object(answer)
        #expect(Set(shot.keys) == ["id", "width", "height", "format", "data"])
        #expect(shot["id"] as? String == id)
        #expect(shot["width"] as? Int == 2 && shot["height"] as? Int == 1)
        #expect(shot["format"] as? String == "png")
        #expect(shot["data"] as? String == Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())
        #expect(rig.machines.calls.events == ["screenshot \(id)"])
    }

    @Test
    func aScreenshotOfAMachineWithAgentAccessOffIsRefusedAndNotTaken() async throws {
        let closed = ControlMachine.fake("closed", access: false)
        let rig = try Rig([closed])
        defer { rig.folder.cleanUp() }
        let answer = await rig.call(
            "machines.screenshot", ["token": .string(try rig.secret()), "machine": .string(closed.id.uuidString)])
        #expect(answer.error?.code == -32003)
        #expect(rig.denials.events.map(\.reason) == [.agentAccessOff])
        #expect(rig.machines.calls.events.isEmpty)
    }

    @Test
    func aRefusedScreenshotIsAnErrorThatSaysWhy() async throws {
        let machine = ControlMachine.fake("m")
        let rig = try Rig([machine], screenshotOutcome: .refused("Screenshots need the custom GPU for now."))
        defer { rig.folder.cleanUp() }
        let answer = await rig.call(
            "machines.screenshot", ["token": .string(try rig.secret()), "machine": .string(machine.id.uuidString)])
        #expect(answer.error == RPCError.refused.with("Screenshots need the custom GPU for now."))
    }

    @Test
    func theLargestScreenshotStillFitsTheLongestAnswerAClientAccepts() async throws {
        let machine = ControlMachine.fake("m")
        // 0xFF bytes are base64 slashes, the character a JSON encoder escapes by default.
        let largest = Data(repeating: 0xFF, count: ControlScreenshot.maximumBytes)
        let shot = ControlScreenshot(id: machine.id, width: 1280, height: 800, png: largest)
        let rig = try Rig([machine], screenshotOutcome: .done(shot))
        defer { rig.folder.cleanUp() }
        let answer = await rig.call(
            "machines.screenshot", ["token": .string(try rig.secret()), "machine": .string(machine.id.uuidString)])
        #expect(answer.error == nil)
        #expect(answer.encoded().count < ControlClient.defaultAnswerBytes)
    }

    @Test
    func aRefusedStartIsAnErrorThatSaysWhy() async throws {
        let machine = ControlMachine.fake("m")
        let rig = try Rig([machine], startOutcome: .refused("“m” is being set up."))
        defer { rig.folder.cleanUp() }
        let secret = try rig.secret()
        let answer = await rig.call("machines.start", ["token": .string(secret), "machine": .string(machine.id.uuidString)])
        #expect(answer.error == RPCError.refused.with("“m” is being set up."))
    }

    @Test
    func noRefusalCarriesTheTokenThatWasPresented() async throws {
        let closed = ControlMachine.fake("closed", access: false)
        let rig = try Rig([closed])
        defer { rig.folder.cleanUp() }
        let weak = try rig.secret([.list])
        let strong = try rig.secret()
        let unknown = ControlSecret.make()
        _ = await rig.call("machines.start", ["token": .string(weak), "machine": .string(closed.id.uuidString)])
        _ = await rig.call("machines.start", ["token": .string(strong), "machine": .string(closed.id.uuidString)])
        _ = await rig.call("machines.list", ["token": .string(unknown)])
        #expect(rig.denials.events.count == 3)
        for denial in rig.denials.events {
            for secret in [weak, strong, unknown] {
                #expect(!String(describing: denial).contains(secret))
                #expect(!denial.summary.contains(secret))
                #expect(!denial.summary.contains(ControlSecret.prefix))
            }
        }
        let otherUser = ControlDenial(reason: .otherUser, peerUser: 501)
        #expect(otherUser.summary == "connection refused: the client runs as another user (user 501)")
    }
}
