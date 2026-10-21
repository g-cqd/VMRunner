import ContainerSpikeCore
import Containerization
import ContainerizationOCI
import Foundation
import Synchronization

/// The run flow of the package's sample command-line tool, in the order that tool uses: a kernel, a container manager that
/// pulls the init image, a pull of alpine, create, start, wait, stop. It runs `uname -a` and records what each step cost.
struct ContainerFlow {
    /// The init image, matched to the pinned package release: the guest and the host speak a versioned protocol.
    static let initReference = "ghcr.io/apple/containerization/vminit:0.52.1"
    static let imageReference = "docker.io/library/alpine:3.24.2"
    static let command = ["uname", "-a"]

    let layout: SpikeLayout

    /// Appends each completed phase to `report`, so a failure half way still tells how far the run got.
    func run(kernel: URL, report: inout SpikeReport) async throws {
        let clock = ContinuousClock()
        var started = clock.now
        func finishPhase(_ name: String) {
            report.phases.append(.init(name: name, duration: started.duration(to: clock.now)))
            started = clock.now
        }

        var manager = try await ContainerManager(
            kernel: Kernel(path: kernel, platform: .linuxArm),
            initfsReference: Self.initReference,
            root: layout.imageStore
        )
        finishPhase("init-image")

        let image = try await manager.imageStore.pull(reference: Self.imageReference, platform: Platform(from: "linux/arm64"))
        finishPhase("pull")

        let id = "spike-\(UUID().uuidString.prefix(8).lowercased())"
        let capture = OutputCapture()
        let memory = UInt64(512) << 20
        let container = try await manager.create(
            id, image: image, rootfsSizeInBytes: UInt64(1) << 30, networking: false,
            vm: VMResources(cpus: 2, memoryInBytes: memory + VMResources.guestMemoryOverhead)
        ) { config in
            config.cpus = 2
            config.memoryInBytes = memory
            config.process.arguments = Self.command
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
            report.verdict = SpikeVerdict.evaluate(exitCode: status.exitCode, output: capture.text)
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
