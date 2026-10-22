import Foundation
import GuestConsole
import Testing
import VMHelperCore

@testable import DevTools

/// The parts of `vmr guest` that surround a booted guest: the scratch directory, the plan, the helper process, and the
/// zboot kernel. Nothing here starts a virtual machine.
struct GuestRunTests {
    // MARK: Scratch directory

    @Test
    func aScratchDirectoryInsideTheLibraryOrTheHomeOrTheRootIsRefused() async throws {
        try await withTemporaryDirectory { home in
            let library = home.appending(path: "Library/Application Support/VMRunner")
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            for path in [library.path, home.appending(path: "Library").path, library.appending(path: "Machines/x").path, home.path, "/"] {
                #expect(throws: ToolError.self, "\(path)") { try GuestScratch(path: path, workingDirectory: home, home: home) }
            }
            // A link that leads into the Library is the Library.
            let link = home.appending(path: "shortcut")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: library)
            #expect(throws: ToolError.self) { try GuestScratch(path: link.appending(path: "run").path, workingDirectory: home, home: home) }
        }
    }

    @Test
    func aScratchDirectoryElsewhereIsAcceptedWhetherOrNotItExistsYet() async throws {
        try await withTemporaryDirectory { home in
            let outside = FileManager.default.temporaryDirectory.appending(path: "vmr-scratch-\(UUID().uuidString)")
            let scratch = try GuestScratch(path: outside.path, workingDirectory: home, home: home)
            #expect(scratch.root == outside.standardizedFileURL)
            #expect(scratch.socket.path == outside.appending(path: "guest/console.sock").standardizedFileURL.path)
            let relative = try GuestScratch(path: "run", workingDirectory: home, home: home)
            #expect(relative.root.path == home.appending(path: "run").path)
            #expect(throws: ToolError.self) { try GuestScratch(path: "", workingDirectory: home, home: home) }
        }
    }

    @Test
    func aDirectoryOpenToOtherUsersIsNotPrivateAndIsNotChanged() async throws {
        try await withTemporaryDirectory { directory in
            let open = directory.appending(path: "open")
            try FileManager.default.createDirectory(at: open, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            #expect(throws: ToolError.self) { try GuestScratch.ensurePrivate(open) }
            let made = directory.appending(path: "made/inner")
            try GuestScratch.ensurePrivate(made)
            let mode = try FileManager.default.attributesOfItem(atPath: made.path)[.posixPermissions] as? Int
            #expect(mode == 0o700)
        }
    }

    // MARK: Plan

    @Test
    func theDefaultPlanIsACappedNetbootGuestBehindAConsoleSocket() throws {
        let scratch = try GuestScratch(path: "/tmp/vmr-plan", workingDirectory: URL(filePath: "/"))
        let files = NetbootFiles(directory: scratch.netbootDirectory, version: "3.24.2")
        let descriptor = try GuestPlan().descriptor(files: files, scratch: scratch)
        try descriptor.validate()
        #expect(descriptor.cpuCount == 2 && descriptor.memoryMiB == 2_048)
        #expect(descriptor.network == .nat)
        #expect(descriptor.disks.isEmpty && descriptor.installerISO == nil)
        #expect(descriptor.boot.kind == .kernel)
        #expect(descriptor.boot.kernel == "/tmp/vmr-plan/netboot/Image-virt")
        #expect(descriptor.boot.initrd == "/tmp/vmr-plan/netboot/initramfs-virt")
        #expect(descriptor.console == .init(socket: "/tmp/vmr-plan/guest/console.sock"))
        let line = try #require(descriptor.boot.commandLine)
        #expect(line.hasPrefix("console=hvc0 ip=dhcp "))
        #expect(line.contains("alpine_repo=https://dl-cdn.alpinelinux.org/alpine/v3.24/main"))
        #expect(line.contains("modloop=https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/netboot-3.24.2/modloop-virt"))
    }

    @Test
    func aPlanAboveTheCapsOrWithABadCommandLineIsRefusedBeforeADescriptorExists() throws {
        let scratch = try GuestScratch(path: "/tmp/vmr-plan", workingDirectory: URL(filePath: "/"))
        let files = NetbootFiles(directory: scratch.netbootDirectory, version: "3.24.2")
        let bad = [
            GuestPlan(cpuCount: 3), GuestPlan(cpuCount: 0), GuestPlan(memoryMiB: 2_049), GuestPlan(memoryMiB: 256),
            GuestPlan(commandLine: ""), GuestPlan(commandLine: "a\nb"),
        ]
        for plan in bad {
            #expect(throws: ToolError.self, "\(plan)") { try plan.descriptor(files: files, scratch: scratch) }
        }
        #expect(throws: Never.self) {
            try GuestPlan(cpuCount: 1, memoryMiB: 512, commandLine: "console=hvc0").descriptor(files: files, scratch: scratch)
        }
    }

    @Test
    func aCustomCommandLineIsUsedAsGiven() throws {
        let scratch = try GuestScratch(path: "/tmp/vmr-plan", workingDirectory: URL(filePath: "/"))
        let files = NetbootFiles(directory: scratch.netbootDirectory, version: "3.24.2")
        let descriptor = try GuestPlan(commandLine: "console=hvc0 quiet").descriptor(files: files, scratch: scratch)
        #expect(descriptor.boot.commandLine == "console=hvc0 quiet")
    }

    @Test
    func startingWithoutAFetchSaysWhatToRunFirst() async throws {
        try await withTemporaryDirectory { directory in
            let scratch = try GuestScratch(path: directory.appending(path: "none").path, workingDirectory: directory)
            let error = #expect(throws: ToolError.self) { try NetbootFiles.existing(in: scratch) }
            #expect(error?.message.contains("vmr guest fetch alpine-netboot") == true)
        }
    }

    // MARK: Zboot kernel

    private func zboot(payload: Data, offset: UInt32 = 64, compression: String = "gzip", magic: String = "zimg") -> Data {
        var header = Data([0x4D, 0x5A, 0, 0]) + Data(magic.utf8)
        for value in [offset, UInt32(payload.count)] {
            header += Data((0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) })
        }
        header += Data(repeating: 0, count: 8) + Data(compression.utf8) + Data(repeating: 0, count: 4)
        return header + Data(repeating: 0, count: max(Int(offset) - header.count, 0)) + payload
    }

    @Test
    func theHeaderOfAZbootImageSaysWhereItsPayloadIs() throws {
        let file = zboot(payload: Data(repeating: 7, count: 100))
        let payload = try ZbootKernel.payload(inHeader: [UInt8](file.prefix(32)), fileSize: file.count)
        #expect(payload == ZbootKernel.Payload(offset: 64, size: 100))
    }

    @Test
    func aHeaderThatIsNotAGzipZbootOrPointsOutsideTheFileIsRefused() {
        let good = zboot(payload: Data(repeating: 7, count: 100))
        let header = [UInt8](good.prefix(32))
        #expect(throws: ToolError.self) { try ZbootKernel.payload(inHeader: Array(header.prefix(20)), fileSize: good.count) }
        #expect(throws: ToolError.self) {
            try ZbootKernel.payload(inHeader: [UInt8](zboot(payload: Data([1]), magic: "nope").prefix(32)), fileSize: 70)
        }
        #expect(throws: ToolError.self) {
            try ZbootKernel.payload(inHeader: [UInt8](zboot(payload: Data([1]), compression: "zstd").prefix(32)), fileSize: 70)
        }
        #expect(throws: ToolError.self) { try ZbootKernel.payload(inHeader: header, fileSize: good.count - 1) }
        #expect(throws: ToolError.self) {
            try ZbootKernel.payload(inHeader: [UInt8](zboot(payload: Data([1]), offset: 16 + 0).prefix(32)), fileSize: 70)
        }
    }

    @Test
    func theKernelImageMustCarryTheArm64Magic() {
        var image = [UInt8](repeating: 0, count: 64)
        #expect(!ZbootKernel.isArm64Image(image))
        image.replaceSubrange(56..<60, with: [0x41, 0x52, 0x4D, 0x64])
        #expect(ZbootKernel.isArm64Image(image))
        #expect(!ZbootKernel.isArm64Image([0x41, 0x52]))
    }

    @Test
    func anUnpackedKernelThatIsNotAnImageIsDeletedAndRefused() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appending(path: "vmlinuz")
            try zboot(payload: Data(repeating: 1, count: 40)).write(to: source)
            let destination = directory.appending(path: "Image")
            await #expect(throws: ToolError.self) {
                try await ZbootKernel.extractImage(from: source, to: destination) { compressed in
                    // A stand-in for gzip: the "decompressed" file is 100 zero bytes.
                    try Data(count: 100).write(to: compressed.deletingPathExtension())
                }
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("gz").path))
        }
    }

    // MARK: Helper process

    @Test
    func aPidFileRoundTripsAndRefusesNonsense() {
        let record = GuestProcess.Record(pid: 4242, executable: "/tmp/x/VMHelper")
        #expect(GuestProcess.Record(text: record.text) == record)
        for bad in ["", "1\n/x\n", "4242\n", "4242\nrelative/path\n", "abc\n/x\n", "4242\n/x\nextra\n", "0\n/x\n"] {
            #expect(GuestProcess.Record(text: bad) == nil, "\(bad.debugDescription)")
        }
    }

    @Test
    func aDetachedProcessIsStartedLoggedAndStoppedAndOnlyItIs() async throws {
        try await withTemporaryDirectory { directory in
            let log = directory.appending(path: "helper.log")
            let program = "/bin/sleep"
            let pid = try GuestProcess.spawnDetached(executable: program, arguments: ["60"], log: log)
            let record = GuestProcess.Record(pid: pid, executable: GuestProcess.executablePath(of: pid) ?? program)
            defer { kill(pid, SIGKILL) }
            #expect(GuestProcess.isRunning(pid))

            let pidFile = directory.appending(path: "helper.pid")
            try GuestProcess.write(record, to: pidFile)
            #expect(GuestProcess.read(from: pidFile) == record)
            let mode = try FileManager.default.attributesOfItem(atPath: pidFile.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)

            // A record naming a different program is not this process, so it is neither live nor signalled.
            let impostor = GuestProcess.Record(pid: pid, executable: "/usr/bin/true")
            #expect(!GuestProcess.isLive(impostor))
            #expect(await GuestProcess.stop(impostor, grace: .seconds(1)) == .notRunning)
            #expect(GuestProcess.isRunning(pid))

            #expect(await GuestProcess.stop(record, grace: .seconds(10)) == .stopped)
            #expect(!GuestProcess.isLive(record))
            #expect(await GuestProcess.stop(record, grace: .seconds(1)) == .notRunning)
            let logMode = try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? Int
            #expect(logMode == 0o600)
        }
    }

    @Test
    func aProgramThatCannotBeStartedIsAnErrorNotACrash() async throws {
        try await withTemporaryDirectory { directory in
            let error = #expect(throws: ToolError.self) {
                try GuestProcess.spawnDetached(
                    executable: directory.appending(path: "missing").path, arguments: [], log: directory.appending(path: "l"))
            }
            #expect(error?.message.contains("cannot start") == true)
        }
    }

    @Test
    func stoppingAGuestThatWasNeverStartedSaysSo() async throws {
        try await withTemporaryDirectory { directory in
            let scratch = try GuestScratch(path: directory.appending(path: "nothing").path, workingDirectory: directory)
            let error = await #expect(throws: ToolError.self) { try await GuestStop(scratch: scratch).run() }
            #expect(error?.message.contains("no guest is recorded") == true)
        }
    }
}
