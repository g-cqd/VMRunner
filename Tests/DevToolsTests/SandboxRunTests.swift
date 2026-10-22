import Foundation
import Testing
import VMHelperCore

@testable import DevTools

/// The pieces of `vmr sandbox` that need no helper and no sandbox: entitlements, log parsing, launch commands and
/// the report, then the command itself on descriptors it must refuse or render.
struct SandboxRunTests {
    private func descriptor(network: HelperDescriptor.Network = .none, disk: String = "/private/vm/disk.img") -> HelperDescriptor {
        HelperDescriptor(
            name: "t", boot: .init(kind: .efi, variableStore: "/private/vm/efi.nvram"), disks: [.init(path: disk)],
            installerISO: "/private/vm/installer.iso", network: network)
    }

    private func grants(_ level: SandboxLevel, network: HelperDescriptor.Network) throws -> SandboxGrants {
        try SandboxGrants(descriptor: descriptor(network: network), descriptorPath: "/private/vm/d.json", level: level)
    }

    // MARK: Entitlements

    private let base: Entitlements.Dictionary = [
        "com.apple.security.app-sandbox": .bool(true), "com.apple.security.virtualization": .bool(true),
    ]

    @Test
    func theAppSandboxEntitlementsCarryEveryGrantedPathAndNothingMore() throws {
        let entitlements = AppSandboxEntitlements.entitlements(base: base, grants: try grants(.strict, network: .none))
        #expect(
            entitlements[AppSandboxEntitlements.readOnlyPaths]
                == .array([.string("/private/vm/d.json"), .string("/private/vm/installer.iso")]))
        #expect(
            entitlements[AppSandboxEntitlements.readWritePaths]
                == .array([.string("/private/vm/disk.img"), .string("/private/vm/efi.nvram")]))
        #expect(entitlements[AppSandboxEntitlements.networkClient] == nil)
        #expect(entitlements["com.apple.security.app-sandbox"] == .bool(true))
        #expect(entitlements.count == 4)
    }

    @Test
    func theNetworkEntitlementComesOnlyWithTheStandardLevelAndAHostedNetwork() throws {
        for (level, network, expected) in [
            (SandboxLevel.standard, HelperDescriptor.Network.fileHandle, true), (.strict, .fileHandle, false), (.standard, .nat, false),
            (.standard, .none, false), (.standard, .filtered, true), (.strict, .filtered, false),
        ] {
            let entitlements = AppSandboxEntitlements.entitlements(base: base, grants: try grants(level, network: network))
            #expect((entitlements[AppSandboxEntitlements.networkClient] != nil) == expected, "\(level) \(network)")
        }
    }

    @Test
    func theGeneratedPropertyListReadsBackAsTheSameEntitlements() throws {
        let entitlements = AppSandboxEntitlements.entitlements(base: base, grants: try grants(.standard, network: .fileHandle))
        let data = try AppSandboxEntitlements.propertyList(entitlements)
        #expect(try Entitlements.parse(data) == entitlements)
        #expect(Entitlements.problems(effective: try Entitlements.parse(data), expected: entitlements, isRelease: true).isEmpty)
    }

    // MARK: Log

    private static let log = """
        Timestamp               Ty Process[PID:TID]
        23:34:21.294 E  kernel[0:283e85] (Sandbox) Sandbox: VMHelper(4242) deny(1) file-read-data /private/etc/hosts
        23:34:21.295 E  kernel[0:283e85] (Sandbox) Sandbox: VMHelper(4242) deny(1) network-outbound remote:*:9
        23:34:21.296 E  kernel[0:283e85] (Sandbox) 4 duplicate reports for Sandbox: VMHelper(4242) deny(1) file-read-data /private/etc/hosts
        23:34:21.297 E  kernel[0:283e85] (Sandbox) Sandbox: VMHelper(4242) deny(1) system-socket domain:32 type:2 protocol:2
        23:34:21.298 E  kernel[0:283e85] (Sandbox) Sandbox: other(99) deny(1) file-read-data /private/etc/passwd
        23:34:21.299 E  kernel[0:283e85] (Sandbox) Sandbox: VMHelper(42420) deny(1) file-read-data /not/this/pid
        23:34:21.300 E  kernel[0:283e85] (Sandbox) Sandbox: VMHelper(4242) deny(1) sysctl-read
        """

    @Test
    func denialsOfOnePidAreCountedWithTheirRepeatsAndTheMostFrequentComesFirst() {
        let denials = SandboxLog.parse(Self.log, pid: 4242)
        #expect(
            denials == [
                SandboxDenial(operation: "file-read-data", target: "/private/etc/hosts", count: 5),
                SandboxDenial(operation: "network-outbound", target: "remote:*:9", count: 1),
                SandboxDenial(operation: "sysctl-read", target: "", count: 1),
                SandboxDenial(operation: "system-socket", target: "domain:32 type:2 protocol:2", count: 1),
            ])
        #expect(SandboxLog.parse(Self.log, pid: 99).map(\.target) == ["/private/etc/passwd"])
        #expect(SandboxLog.parse("", pid: 1).isEmpty)
    }

    @Test
    func theLogIsAskedForTheSandboxSenderAndOnePid() {
        let arguments = SandboxLog.arguments(pid: 77, lastSeconds: 0)
        #expect(
            arguments == [
                "show", "--last", "1s", "--style", "compact", "--predicate", #"sender == "Sandbox" AND eventMessage CONTAINS "(77) deny""#,
            ])
    }

    // MARK: Launch

    @Test
    func eachEngineLaunchesTheHelperItsOwnWay() {
        let plain = SandboxLaunch.make(engine: .none, helper: "/b/plain/VMHelper", profile: nil)
        #expect(plain.executable == "/b/plain/VMHelper" && plain.leadingArguments.isEmpty)
        let bundle = SandboxLaunch.make(engine: .appSandbox, helper: "/b/VMHelper.app/Contents/MacOS/VMHelper", profile: nil)
        #expect(bundle.executable == "/b/VMHelper.app/Contents/MacOS/VMHelper")
        let seatbelt = SandboxLaunch.make(engine: .seatbelt, helper: "/b/plain/VMHelper", profile: "/b/p.sb")
        #expect(seatbelt.executable == "/usr/bin/sandbox-exec")
        #expect(seatbelt.leadingArguments == ["-f", "/b/p.sb", "/b/plain/VMHelper"])
        #expect(seatbelt.helperPath == "/b/plain/VMHelper")
    }

    @Test
    func theHelperIsGivenItsModeItsDescriptorAndOnlyWhenBootingItsRunTime() {
        let launch = SandboxLaunch.make(engine: .seatbelt, helper: "/h", profile: "/p.sb")
        let probe = launch.command(mode: .probe, descriptorPath: "/d.json", runSeconds: 9, timeout: .seconds(5))
        #expect(probe.arguments == ["-f", "/p.sb", "/h", "--probe", "--descriptor", "/d.json"])
        #expect(probe.timeout == .seconds(5))
        #expect(
            launch.command(mode: .dryRun, descriptorPath: "/d.json", runSeconds: 9, timeout: .seconds(5)).arguments.suffix(3) == [
                "--dry-run", "--descriptor", "/d.json",
            ])
        #expect(
            launch.command(mode: .start, descriptorPath: "/d.json", runSeconds: 9, timeout: .seconds(5)).arguments.suffix(2) == [
                "--run-seconds", "9",
            ])
    }

    // MARK: Report

    private func event(
        _ kind: HelperEvent.Kind, at time: Double, message: String? = nil, check: String? = nil, verdict: HelperEvent.Verdict? = nil
    )
        -> HelperEvent
    {
        HelperEvent(kind, time: time, pid: 4242, message: message, check: check, verdict: verdict)
    }

    private func phase(
        _ mode: SandboxPhase.Mode, status: Int32 = 0, events: [HelperEvent] = [], console: SandboxPhase.Console? = nil,
        denials: [SandboxDenial]? = []
    ) -> SandboxPhase {
        SandboxPhase(mode: mode, status: status, timedOut: false, events: events, console: console, denials: denials, seconds: 1.5)
    }

    private func probe(refusing refused: Set<String>, resolve: HelperEvent.Verdict = .allowed) -> SandboxPhase {
        var events = ProbeCheck.userModeStack.map {
            event(.probe, at: 0.1, message: "m", check: $0, verdict: refused.contains($0) ? .refused : .allowed)
        }
        events.append(event(.probe, at: 0.1, message: "gai failed", check: ProbeCheck.resolve(ProbeCheck.remoteHost), verdict: resolve))
        return phase(.probe, events: events)
    }

    @Test
    func networkingWorksOnlyWhenEveryOperationOfAUserModeStackWentThrough() {
        #expect(SandboxReport.networking(probe(refusing: [])).hasPrefix("works"))
        let refused = SandboxReport.networking(probe(refusing: [ProbeCheck.tcpConnect, ProbeCheck.icmpConnect]))
        #expect(refused == "refused: \(ProbeCheck.tcpConnect); \(ProbeCheck.icmpConnect)")
        #expect(SandboxReport.networking(nil) == "not probed")
        #expect(SandboxReport.networking(phase(.probe)) == "not probed")
    }

    @Test
    func nameResolutionReportsTheResolverMessageWhenItFails() {
        #expect(SandboxReport.resolution(probe(refusing: [])).hasPrefix("works"))
        let failed = SandboxReport.resolution(probe(refusing: [], resolve: .refused))
        #expect(failed.hasPrefix("fails (example.com: gai failed)"))
    }

    @Test
    func bootingIsOnlyClaimedWhenTheHelperReportedRunning() {
        #expect(SandboxReport.boots(nil).hasPrefix("not run"))
        let booted = phase(
            .start, events: [event(.booting, at: 0.2), event(.running, at: 1.7)], console: .init(lines: 40, firstLineAfterBooting: 0.9))
        #expect(SandboxReport.boots(booted) == "yes: the framework reported the machine running after 1.700 s")
        #expect(SandboxReport.bootTime(booted).hasPrefix("1.500 s from booting to running"))
        #expect(SandboxReport.bootTime(booted).contains("first console line came 0.900 s after booting (40 lines)"))
        let failed = phase(
            .start, status: 70, events: [event(.booting, at: 0.2), event(.error, at: 0.4, message: "the machine failed to start: boom")])
        #expect(SandboxReport.boots(failed) == "no: the machine failed to start: boom")
        #expect(SandboxReport.bootTime(failed) == "not measured")
        #expect(
            SandboxReport.bootTime(phase(.start, events: [event(.running, at: 1)], console: .init(lines: 0, firstLineAfterBooting: nil)))
                .contains("wrote nothing"))
    }

    @Test
    func theReportListsDenialsRefusedProbesAndAnAbortWithoutAnyEvent() {
        let denial = SandboxDenial(operation: "network-outbound", target: "remote:*:9", count: 3)
        let lines = SandboxReport.lines(
            engine: .seatbelt, level: .strict, descriptorPath: "/d.json", helperPath: "/h",
            phases: [probe(refusing: [ProbeCheck.tcpConnect]).withDenials([denial]), phase(.dryRun, status: 134, denials: nil)])
        #expect(lines.contains("sandbox denials:      3 logged (details below)"))
        #expect(lines.contains("  log: 3x network-outbound remote:*:9"))
        #expect(lines.contains { $0.hasPrefix("  refused:  \(ProbeCheck.tcpConnect)") })
        #expect(lines.contains { $0.hasPrefix("dry-run: exit status 134 (aborted by the system") })
        #expect(lines.contains("  log: not collected (the helper reported no pid, or `log show` failed)"))
        #expect(
            lines.contains { $0.hasPrefix("dry run:              failed: no error event; aborted by the system") })
        #expect(lines.contains("boots at all:         not run (starting a virtual machine needs --boot, which only the owner passes)"))
    }

    @Test
    func consoleLinesAreTheOnesThatAreNotEventsAndTheFirstIsTimedFromBooting() throws {
        let origin = ContinuousClock.now
        let recorded: [(text: String, at: ContinuousClock.Instant)] = [
            ("early console line before booting", origin),
            (try event(.booting, at: 0).line(), origin + .seconds(1)),
            ("Booting Linux", origin + .milliseconds(1_500)),
            ("login:", origin + .seconds(3)),
            (try event(.running, at: 0.4).line(), origin + .seconds(2)),
        ]
        let (events, console) = SandboxRun.separate(recorded)
        #expect(events.map(\.event) == [.booting, .running])
        #expect(console.lines == 3)
        #expect(console.firstLineAfterBooting == 0.5)
    }

    // MARK: Command

    private func runSandbox(_ arguments: [String], descriptor: String) async throws -> Invocation {
        try await withTemporaryDirectory { directory in
            try write(["Package.swift": "// swift-tools-version: 6.0\n", "d.json": descriptor], to: directory)
            return try await VMR.vmr(["sandbox"] + arguments + ["--descriptor", "d.json", "--root", directory.path], in: directory)
        }
    }

    private func json(disk: String) -> String {
        let disk = disk.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"").replacing("\n", with: "\\n")
        let boot = #"{"kind":"efi","variableStore":"/tmp/vmr-sandbox-efi"}"#
        return #"{"version":1,"name":"t","boot":\#(boot),"disks":[{"path":"\#(disk)"}],"network":"fileHandle"}"#
    }

    @Test
    func theProfileCommandPrintsTheGeneratedProfileForADescriptor() async throws {
        let run = try await runSandbox(
            ["profile", "--level", "standard", "--helper", "/private/tmp/h/VMHelper"],
            descriptor: json(disk: "/private/tmp/My Disk (2).img"))
        #expect(run.status == 0, "\(run.combined)")
        let lines = run.outputLines
        #expect(lines.first == "(version 1)")
        #expect(lines.contains("(deny default)"))
        #expect(lines.contains(#"(allow file-read* file-write* (literal "/private/tmp/My Disk (2).img"))"#), "\(run.output)")
        #expect(lines.contains(#"(allow process-exec (literal "/private/tmp/h/VMHelper"))"#))
        #expect(lines.contains { $0.contains("(remote ip") }, "the standard level with a hosted network may connect")
    }

    @Test
    func theStrictProfileHasNoNetworkRules() async throws {
        let run = try await runSandbox(
            ["profile", "--level", "strict", "--helper", "/private/tmp/h/VMHelper"], descriptor: json(disk: "/private/tmp/d.img"))
        #expect(run.status == 0, "\(run.combined)")
        #expect(!run.output.contains("network-"), "\(run.output)")
    }

    @Test(arguments: ["/tmp/a\"b", "/tmp/a\nb", "/tmp/a\\b", "/tmp/../etc/passwd", "relative.img"])
    func aHostilePathInTheDescriptorIsRefusedBeforeAnythingIsBuilt(path: String) async throws {
        for arguments in [["profile"], ["run", "--engine", "seatbelt"]] {
            let run = try await runSandbox(arguments, descriptor: json(disk: path))
            #expect(run.status == 65, "\(arguments) \(run.combined)")
            #expect(run.error.hasPrefix("error: "), "\(run.error)")
            #expect(!run.output.contains("(allow"), "no profile text is printed for a refused descriptor")
        }
    }

    @Test
    func anUnknownEngineOrLevelIsAUsageError() async throws {
        let engine = try await runSandbox(["run", "--engine", "chroot"], descriptor: json(disk: "/tmp/d.img"))
        #expect(engine.status != 0)
        #expect(engine.error.contains("'chroot' is not one of none, app-sandbox, seatbelt"), "\(engine.error)")
        let level = try await runSandbox(["profile", "--level", "lax"], descriptor: json(disk: "/tmp/d.img"))
        #expect(level.status != 0)
        #expect(level.error.contains("'lax' is not one of standard, strict"), "\(level.error)")
    }
}

extension SandboxPhase {
    fileprivate func withDenials(_ denials: [SandboxDenial]) -> SandboxPhase {
        SandboxPhase(mode: mode, status: status, timedOut: timedOut, events: events, console: console, denials: denials, seconds: seconds)
    }
}
