import ContainerRunnerCore
import Containerization
import ContainerizationOCI
import Foundation
import Synchronization

/// The run flow of the package's sample command-line tool, in the order that tool uses: a kernel, a container manager that
/// pulls the init image, a pull of alpine, create, start, wait, stop. It runs `uname -a` and records what each step cost.
/// With a loopback network the container also pings its gateway, and the frames its network device delivered are reported.
struct ContainerFlow {
    /// The init image, matched to the pinned package release: the guest and the host speak a versioned protocol.
    static let initReference = "ghcr.io/apple/containerization/vminit:0.52.1"
    static let imageReference = "docker.io/library/alpine:3.24.2"

    let layout: RunnerLayout
    let network: RunnerArguments.Network

    /// The container's command. The ping has no reply to get, so the shell ends with status 0 regardless; the frames the
    /// ping caused are the result, not the ping's own status.
    private var command: [String] {
        switch network {
        case .none: ["uname", "-a"]
        case .loopback: ["/bin/sh", "-c", "uname -a; ping -c 1 -W 2 \(NetworkVerdict.gatewayAddress) >/dev/null 2>&1; exit 0"]
        }
    }

    /// Appends each completed phase to `report`, so a failure half way still tells how far the run got.
    func run(kernel: URL, report: inout RunnerReport) async throws {
        guard network == .loopback else {
            try await execute(kernel: kernel, link: nil, report: &report)
            return
        }
        let link = try LoopbackLink()
        let collector = Task {
            var seen: [FrameSummary] = []
            for await bytes in link.frames {
                if let frame = FrameSummary.parse(bytes) { seen.append(frame) }
            }
            return seen
        }
        var failure: (any Error)?
        do {
            try await execute(kernel: kernel, link: link, report: &report)
        } catch {
            failure = error
        }
        link.stop()
        report.frames = await collector.value
        report.networkVerdict = NetworkVerdict.evaluate(frames: report.frames)
        if let failure { throw failure }
    }

    private func execute(kernel: URL, link: LoopbackLink?, report: inout RunnerReport) async throws {
        let clock = ContinuousClock()
        var started = clock.now
        func finishPhase(_ name: String) {
            report.phases.append(.init(name: name, duration: started.duration(to: clock.now)))
            started = clock.now
        }

        var manager = try await ContainerManager(
            kernel: Kernel(path: kernel, platform: .linuxArm),
            initfsReference: Self.initReference,
            root: layout.imageStore,
            network: link.map { LoopbackNetwork(link: $0) }
        )
        finishPhase("init-image")

        let image = try await manager.imageStore.pull(reference: Self.imageReference, platform: Platform(from: "linux/arm64"))
        finishPhase("pull")

        let id = "runner-\(UUID().uuidString.prefix(8).lowercased())"
        let capture = OutputCapture()
        let memory = UInt64(512) << 20
        let command = command
        let container = try await manager.create(
            id, image: image, rootfsSizeInBytes: UInt64(1) << 30, networking: link != nil,
            vm: VMResources(cpus: 2, memoryInBytes: memory + VMResources.guestMemoryOverhead)
        ) { config in
            config.cpus = 2
            config.memoryInBytes = memory
            config.process.arguments = command
            config.process.stdout = capture
            config.process.stderr = capture
        }
        finishPhase("create")

        do {
            try await container.create()
            finishPhase("boot")
            try await container.start()
            let status = try await container.wait()
            finishPhase("run")
            try await container.stop()
            report.output = capture.text
            report.exitCode = status.exitCode
            report.verdict = RunnerVerdict.evaluate(exitCode: status.exitCode, output: capture.text)
        } catch {
            try? await container.stop()
            Console.line("boot log kept at \(layout.imageStore.path)/containers/\(id)/bootlog.log", to: .error)
            throw error
        }
        do {
            try manager.delete(id)
        } catch {
            Console.line("warning: could not remove container \(id): \(error)", to: .error)
        }
    }
}

/// Collects what the container writes to a stream.
private final class OutputCapture: Writer, Sendable {
    private let bytes = Mutex(Data())

    var text: String { bytes.withLock { String(bytes: $0, encoding: .utf8) ?? "" } }

    func write(_ data: Data) throws {
        bytes.withLock { $0.append(data) }
    }

    func close() throws {}
}
