import Foundation
import Synchronization
import Testing
import VMHelperCore

@testable import DevTools

/// A guest on the filtered network: the plan, the target a command names, the flow lines, and the policy update, with a fake
/// helper that reads the command pipe and writes the log.
struct GuestNetworkTests {
    // MARK: Plan

    private func files(in scratch: GuestScratch) -> NetbootFiles {
        NetbootFiles(directory: scratch.netbootDirectory, version: "3.24.2")
    }

    @Test
    func aFilteredPlanNamesThePolicyFileInTheRunDirectoryAndTheDenyAction() throws {
        let scratch = try GuestScratch(path: "/tmp/vmr-net", workingDirectory: URL(filePath: "/"))
        var plan = GuestPlan()
        plan.network = .filtered
        plan.denyAction = .drop
        let descriptor = try plan.descriptor(files: files(in: scratch), scratch: scratch)
        try descriptor.validate()
        #expect(descriptor.network == .filtered)
        #expect(descriptor.networkPolicy == "/tmp/vmr-net/guest/policy.json")
        #expect(descriptor.denyAction == .drop)
        #expect(descriptor.readPaths.contains("/tmp/vmr-net/guest/policy.json"))
    }

    @Test
    func aNatPlanHasNoPolicyAndAPolicyWithoutAFilteredNetworkIsRefused() throws {
        let scratch = try GuestScratch(path: "/tmp/vmr-net", workingDirectory: URL(filePath: "/"))
        let nat = try GuestPlan().descriptor(files: files(in: scratch), scratch: scratch)
        #expect(nat.network == .nat && nat.networkPolicy == nil)
        var withPolicy = GuestPlan()
        withPolicy.policyFile = URL(filePath: "/tmp/p.json")
        #expect(throws: ToolError.self) { try withPolicy.validate() }
        var withDeny = GuestPlan()
        withDeny.denyAction = .drop
        #expect(throws: ToolError.self) { try withDeny.validate() }
        for network in [HelperDescriptor.Network.none, .fileHandle] {
            var plan = GuestPlan()
            plan.network = network
            #expect(throws: ToolError.self, "\(network)") { try plan.validate() }
        }
    }

    @Test
    func aPolicyFileMustBeAJsonObjectOfReasonableSize() async throws {
        try await withTemporaryDirectory { directory in
            let good = directory.appending(path: "good.json")
            try Data(#"{"blockedDomains":["example.com"]}"#.utf8).write(to: good)
            #expect(try GuestPlan.policyText(of: good) == Data(#"{"blockedDomains":["example.com"]}"#.utf8))
            for (name, text) in [("array.json", "[1]"), ("text.txt", "block everything"), ("empty.json", "")] {
                let file = directory.appending(path: name)
                try Data(text.utf8).write(to: file)
                #expect(throws: ToolError.self, "\(name)") { try GuestPlan.policyText(of: file) }
            }
            let big = directory.appending(path: "big.json")
            try Data(#"{"a":""#.utf8 + Data(repeating: 0x61, count: GuestPlan.policyLimit) + Data(#""}"#.utf8)).write(to: big)
            #expect(throws: ToolError.self) { try GuestPlan.policyText(of: big) }
            #expect(throws: ToolError.self) { try GuestPlan.policyText(of: directory.appending(path: "missing.json")) }
        }
    }

    // MARK: Target

    /// A scratch directory with the files of a started guest.
    private func startedGuest(in directory: URL) throws -> (root: URL, socket: String) {
        let root = directory.appending(path: "run", directoryHint: .isDirectory)
        let run = root.appending(path: "guest", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("{}".utf8).write(to: run.appending(path: "descriptor.json"))
        try Data().write(to: run.appending(path: "console.sock"))
        return (root, run.appending(path: "console.sock").path)
    }

    @Test
    func aSocketADirectoryOrAScratchDirectoryNamesTheSameGuest() async throws {
        try await withTemporaryDirectory { directory in
            let (root, socket) = try startedGuest(in: directory)
            for argument in [socket, root.path, root.appending(path: "guest").path] {
                let scratch = try await GuestTarget.scratch(for: argument, workingDirectory: directory)
                #expect(scratch.root == root.standardizedFileURL, "\(argument)")
            }
        }
    }

    @Test
    func aPidNamesTheGuestItsHelperWasStartedFor() async throws {
        try await withTemporaryDirectory { directory in
            let (root, _) = try startedGuest(in: directory)
            let descriptor = root.appending(path: "guest/descriptor.json").path
            let line = "/x/VMHelper --start --descriptor \(descriptor) --run-seconds 900 --commands"
            let scratch = try await GuestTarget.scratch(for: "4242", workingDirectory: directory) { pid in pid == 4242 ? line : nil }
            #expect(scratch.root == root.standardizedFileURL)
            await #expect(throws: ToolError.self) {
                try await GuestTarget.scratch(for: "4243", workingDirectory: directory) { _ in nil }
            }
            await #expect(throws: ToolError.self) {
                try await GuestTarget.scratch(for: "4244", workingDirectory: directory) { _ in "/usr/bin/sleep 100" }
            }
        }
    }

    @Test
    func theDescriptorIsTheWordAfterTheFlagAndMustBeAbsolute() {
        #expect(GuestTarget.descriptorPath(inCommandLine: "/x/VMHelper --start --descriptor /a/b.json --run-seconds 9") == "/a/b.json")
        #expect(GuestTarget.descriptorPath(inCommandLine: "/x/VMHelper --descriptor") == nil)
        #expect(GuestTarget.descriptorPath(inCommandLine: "/x/VMHelper --descriptor relative.json") == nil)
        #expect(GuestTarget.descriptorPath(inCommandLine: "/usr/bin/sleep 100") == nil)
    }

    @Test
    func somethingThatIsNotAGuestIsRefused() async throws {
        try await withTemporaryDirectory { directory in
            await #expect(throws: ToolError.self) { try await GuestTarget.scratch(for: "nothing-here", workingDirectory: directory) }
            await #expect(throws: ToolError.self) { try await GuestTarget.scratch(for: directory.path, workingDirectory: directory) }
        }
    }

    // MARK: Flows

    private func event(_ kind: HelperEvent.Kind, _ time: Double, _ message: String, check: String? = nil) throws -> String {
        try HelperEvent(kind, time: time, pid: 1, message: message, check: check).line()
    }

    private func logOfAGuest(in directory: URL) throws -> GuestScratch {
        let (root, _) = try startedGuest(in: directory)
        let scratch = try GuestScratch(path: root.path, workingDirectory: directory)
        let lines = [
            try event(.booting, 0.1, ""), try event(.statistics, 1, "tcpFlowsOpened=0"),
            try event(.flow, 2.5, "DNS answered example.com: Name resolved", check: "answered"),
            try event(.flow, 2.75, "TCP allowed example.com (93.184.216.34:80)", check: "allowed"),
            try event(.flow, 3.0, "TCP denied 10.0.0.1:22: 10.0.0.1 is a private network address", check: "denied"),
            try event(.statistics, 6, "tcpFlowsOpened=1 tcpFlowsDenied=1"),
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: scratch.logFile)
        return scratch
    }

    @Test
    func theFlowLinesAreTheEventsInOrderWithTheirTimeAndTheLatestCounters() async throws {
        try await withTemporaryDirectory { directory in
            let flows = GuestFlows(scratch: try logOfAGuest(in: directory))
            #expect(
                try flows.lines() == [
                    "[    2.500] DNS answered example.com: Name resolved", "[    2.750] TCP allowed example.com (93.184.216.34:80)",
                    "[    3.000] TCP denied 10.0.0.1:22: 10.0.0.1 is a private network address",
                    "counters: tcpFlowsOpened=1 tcpFlowsDenied=1",
                ])
        }
    }

    @Test
    func theGuestVpnVerdictsAreShownBetweenTheFlowsUnlessAnOutcomeNarrowsTheList() async throws {
        try await withTemporaryDirectory { directory in
            let scratch = try logOfAGuest(in: directory)
            let vpn = try event(.vpn, 2.9, "Guest VPN: WireGuard suspected (medium confidence)")
            let handle = try FileHandle(forWritingTo: scratch.logFile)
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: Data((vpn + "\n").utf8))
            try handle.close()
            var flows = GuestFlows(scratch: scratch)
            #expect(try flows.lines().contains("[    2.900] Guest VPN: WireGuard suspected (medium confidence)"))
            flows.outcome = "denied"
            #expect(try !flows.lines().contains { $0.contains("Guest VPN") })
        }
    }

    @Test
    func onlyTheNewestLinesOrOnlyOneOutcomeCanBeAsked() async throws {
        try await withTemporaryDirectory { directory in
            var flows = GuestFlows(scratch: try logOfAGuest(in: directory))
            flows.last = 1
            #expect(try flows.lines().count == 2, "the newest flow line and the counters")
            flows.last = 50
            flows.outcome = "denied"
            let denied = try flows.lines()
            #expect(denied.count == 2 && denied[0].contains("TCP denied 10.0.0.1:22"))
            flows.outcome = "revoked"
            #expect(try flows.lines().first == "no flow events with the outcome revoked")
        }
    }

    @Test
    func aLogWithNoEventsIsNotAGuest() async throws {
        try await withTemporaryDirectory { directory in
            let (root, _) = try startedGuest(in: directory)
            let scratch = try GuestScratch(path: root.path, workingDirectory: directory)
            #expect(throws: ToolError.self) { try GuestFlows(scratch: scratch).lines() }
        }
    }

    // MARK: Live policy update

    /// A stand-in for a helper: this process is the "helper", a thread reads the command pipe the way the real one does and
    /// answers in the log.
    private final class Recorded: Sendable {
        private let lines = Mutex<[String]>([])
        func append(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }

    private final class FakeHelper: Sendable {
        let commands = Recorded()

        init(scratch: GuestScratch, answer: @escaping @Sendable (String) -> (check: String, message: String)?) throws {
            let pipe = scratch.commandPipe.path
            guard unsafe mkfifo(pipe, 0o600) == 0 else { throw TestSetupError("mkfifo failed: \(errno)") }
            let descriptor = unsafe open(pipe, O_RDWR)
            guard descriptor >= 0 else { throw TestSetupError("open failed: \(errno)") }
            let log = scratch.logFile
            let commands = commands
            let thread = Thread {
                var pending = Data()
                var buffer = [UInt8](repeating: 0, count: 256)
                // Ends, closing the pipe, when the test has removed it with its directory.
                defer { close(descriptor) }
                while FileManager.default.fileExists(atPath: pipe) {
                    var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                    guard unsafe poll(&entry, 1, 50) > 0 else { continue }
                    let count = buffer.withUnsafeMutableBytes { unsafe read(descriptor, $0.baseAddress, $0.count) }
                    guard count > 0 else { break }
                    pending.append(contentsOf: buffer[0..<count])
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = String(bytes: pending[pending.startIndex..<newline], encoding: .utf8) ?? ""
                        pending.removeSubrange(pending.startIndex...newline)
                        commands.append(line)
                        guard let reply = answer(line),
                            let text = try? HelperEvent(.policy, time: 1, pid: 1, message: reply.message, check: reply.check).line()
                        else { continue }
                        if let handle = try? FileHandle(forWritingTo: log) {
                            _ = try? handle.seekToEnd()
                            try? handle.write(contentsOf: Data((text + "\n").utf8))
                            try? handle.close()
                        }
                    }
                }
            }
            thread.start()
        }
    }

    private func filteredGuest(in directory: URL, network: HelperDescriptor.Network = .filtered) throws -> GuestScratch {
        let (root, _) = try startedGuest(in: directory)
        let scratch = try GuestScratch(path: root.path, workingDirectory: directory)
        let descriptor = HelperDescriptor(
            name: "t", boot: .init(kind: .kernel, kernel: "/k", initrd: "/i"), network: network,
            networkPolicy: network == .filtered ? scratch.policyFile.path : nil)
        try JSONEncoder().encode(descriptor).write(to: scratch.descriptorFile)
        try Data("{}\n".utf8).write(to: scratch.policyFile)
        try Data().write(to: scratch.logFile)
        let me = getpid()
        try GuestProcess.write(.init(pid: me, executable: GuestProcess.executablePath(of: me) ?? "/none"), to: scratch.pidFile)
        return scratch
    }

    @Test
    func aNewPolicyReplacesTheFileAndSendsTheCommandAndReportsTheAnswer() async throws {
        try await withTemporaryDirectory { directory in
            let scratch = try filteredGuest(in: directory)
            let helper = try FakeHelper(scratch: scratch) { _ in ("applied", "policy.json") }
            let file = directory.appending(path: "new.json")
            try Data(#"{"blockedDomains":["example.com"]}"#.utf8).write(to: file)

            let answer = try await GuestPolicy(scratch: scratch, file: file).run()
            #expect(answer == .init(applied: true, message: "policy.json"))
            #expect(helper.commands.all == ["policy terminate"])
            #expect(try Data(contentsOf: scratch.policyFile) == Data(#"{"blockedDomains":["example.com"]}"#.utf8))
            let mode = try FileManager.default.attributesOfItem(atPath: scratch.policyFile.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)

            var keeping = GuestPolicy(scratch: scratch, file: file)
            keeping.terminatingOpenFlows = false
            _ = try await keeping.run()
            #expect(helper.commands.all == ["policy terminate", "policy keep"])
        }
    }

    @Test
    func aRejectedPolicyIsReportedAsSuch() async throws {
        try await withTemporaryDirectory { directory in
            let scratch = try filteredGuest(in: directory)
            _ = try FakeHelper(scratch: scratch) { _ in ("rejected", "the network policy is not a policy") }
            let file = directory.appending(path: "bad.json")
            try Data(#"{"mode":"nonsense"}"#.utf8).write(to: file)
            let answer = try await GuestPolicy(scratch: scratch, file: file).run()
            #expect(answer == .init(applied: false, message: "the network policy is not a policy"))
        }
    }

    @Test
    func aHelperThatDoesNotAnswerMakesTheUpdateFailAfterTheTimeout() async throws {
        try await withTemporaryDirectory { directory in
            let scratch = try filteredGuest(in: directory)
            _ = try FakeHelper(scratch: scratch) { _ in nil }
            let file = directory.appending(path: "p.json")
            try Data("{}".utf8).write(to: file)
            var update = GuestPolicy(scratch: scratch, file: file)
            update.timeout = .milliseconds(150)
            let error = await #expect(throws: ToolError.self) { try await update.run() }
            #expect(error?.message.contains("did not answer") == true)
        }
    }

    @Test
    func anOldAnswerInTheLogIsNotTakenForTheNewOne() async throws {
        try await withTemporaryDirectory { directory in
            let scratch = try filteredGuest(in: directory)
            try Data((try event(.policy, 0.5, "old.json", check: "applied") + "\n").utf8).write(to: scratch.logFile)
            _ = try FakeHelper(scratch: scratch) { _ in ("rejected", "fresh answer") }
            let file = directory.appending(path: "p.json")
            try Data("{}".utf8).write(to: file)
            #expect(try await GuestPolicy(scratch: scratch, file: file).run().message == "fresh answer")
        }
    }

    @Test
    func aGuestThatIsNotFilteredOrNotRunningCannotTakeAPolicy() async throws {
        try await withTemporaryDirectory { directory in
            let natGuest = try filteredGuest(in: directory, network: .nat)
            let file = directory.appending(path: "p.json")
            try Data("{}".utf8).write(to: file)
            let error = await #expect(throws: ToolError.self) { try await GuestPolicy(scratch: natGuest, file: file).run() }
            #expect(error?.message.contains("--net filtered") == true)

            try FileManager.default.removeItem(at: natGuest.pidFile)
            await #expect(throws: ToolError.self) { try await GuestPolicy(scratch: natGuest, file: file).run() }
        }
    }
}
