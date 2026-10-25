import CryptoKit
import Foundation
import Testing

@testable import VMRunner

/// The Windows preset of the New Machine sheet: the defaults it applies, the installer check against an expected SHA-256, the
/// driver disc, the refusal of a source that is not a local file, and the words the requirements panel says.
@MainActor
struct WindowsNewMachineTests {
    private func makeModel(_ scratch: ScratchDefaults) -> NewMachineModel {
        let model = NewMachineModel(defaults: scratch.defaults)
        model.guestChanged(to: .windows)
        return model
    }

    private func write(_ text: String, named name: String, in directory: URL) throws -> URL {
        let url = directory.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func sha256(of text: String) -> String { SHA256.hash(data: Data(text.utf8)).hexString }

    // MARK: The preset

    @Test func theSheetOffersWindowsAfterMacOSAndLinux() {
        #expect(GuestOS.newMachineChoices == [.macOS, .linux, .windows])
    }

    @Test func switchingToWindowsAppliesTheWindowsDefaults() throws {
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let model = NewMachineModel(defaults: scratch.defaults)
        let id = model.config.id
        model.localPath = "/Users/me/restore.ipsw"
        model.driverDiscPath = "/Users/me/drivers.iso"
        model.expectedSHA256 = "abc"

        model.guestChanged(to: .windows)

        let host = ProcessInfo.processInfo
        let expected = VMConfig.new(
            name: "Windows", guest: .windows, hostCPUs: host.activeProcessorCount, hostMemoryGiB: Int(host.physicalMemory >> 30))
        #expect(model.config == expected.withID(id))
        #expect(model.config.name == "Windows" && model.config.guest == .windows)
        #expect(model.config.diskGiB == 64 && model.config.diskInterface == .nvme && model.config.networkMode == .nat)
        #expect(model.config.displayWidth == 1920 && model.config.displayHeight == 1200)
        #expect((2...4).contains(model.config.cpuCount) && model.config.memoryMiB <= 8192)
        #expect(model.localPath == nil && model.driverDiscPath == nil && model.expectedSHA256.isEmpty)
    }

    @Test func switchingToWindowsKeepsATypedNameAndPutsTheDiskInsideTheWindowsRange() throws {
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let model = NewMachineModel(defaults: scratch.defaults)
        model.guestChanged(to: .linux)
        model.config.diskGiB = 16
        model.config.name = "build agent"

        model.guestChanged(to: .windows)

        #expect(model.config.name == "build agent")
        #expect(EditorLimits.newDiskGiB(for: .windows).contains(model.config.diskGiB))
        #expect(model.config.diskGiB >= 64)
        model.guestChanged(to: .macOS)
        #expect(model.localPath == nil && model.driverDiscPath == nil)
    }

    @Test func theMachineThePresetMakesValidatesAndApprovesItsMediaReadOnly() throws {
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let model = makeModel(scratch)
        model.chooseLocalFile(URL(filePath: "/Users/me/Win11_arm64.iso"))
        model.chooseDriverDisc(URL(filePath: "/Users/me/drivers.iso"))

        let config = model.makeConfig()

        try config.validate()
        #expect(model.canCreate)
        #expect(config.source == .local("/Users/me/Win11_arm64.iso"))
        #expect(config.driverDiscPath == "/Users/me/drivers.iso")
        #expect(config.hostGrants == [HostPathGrant(.driverDisc, "/Users/me/drivers.iso", writable: false)])
        #expect(try VMConfig.decode(from: config.encoded()) == config)
    }

    @Test func aWindowsMachineNeedsItsInstallerAndAUsableDriverDiscLocation() throws {
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let model = makeModel(scratch)
        #expect(!model.canCreate, "no installer chosen")
        model.localPath = "/Users/me/Win11_arm64.iso"
        #expect(model.canCreate)

        model.chooseDriverDisc(URL(filePath: AppPaths.machines.appending(path: "x.iso").path))
        #expect(model.driverDiscPath == nil && model.creationError != nil)
        model.driverDiscPath = "relative/drivers.iso"
        #expect(!model.canCreate, "a driver disc whose location cannot be stored")
        model.driverDiscPath = nil
        #expect(model.canCreate)
    }

    // MARK: A source that is not a local file

    @Test func aWindowsConfigurationRefusesASourceThatIsNotALocalFile() throws {
        let sources: [ImageSource] = [
            .latestMac, .linuxCatalog(id: "debian"), .remote(try #require(URL(string: "https://example.com/w.iso")), checksum: nil),
        ]
        for source in sources {
            var config = VMConfig.new(name: "w", guest: .windows)
            config.source = source
            #expect(throws: DecodingError.self) { try config.validate() }
            #expect(throws: DecodingError.self) { try VMConfig.decode(from: config.encoded()) }
            config.guest = .linux
            try config.validate()
        }
        var local = VMConfig.new(name: "w", guest: .windows)
        local.source = .local("/Users/me/Win11_arm64.iso")
        try local.validate()
        local.source = nil
        try local.validate()
    }

    @Test func theSheetNeverGivesAWindowsMachineAnythingButALocalSource() throws {
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let model = makeModel(scratch)
        #expect(model.makeConfig().source == nil)
        model.macSource = .ipswMe
        model.selectedBuild = "26A434"
        model.config.source = .latestMac
        model.localPath = "/Users/me/Win11_arm64.iso"
        #expect(model.makeConfig().source == .local("/Users/me/Win11_arm64.iso"))
    }

    // MARK: The expected SHA-256

    @Test func aMatchingDigestPassesWhateverItsCaseAndPadding() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try write("installer bytes", named: "w.iso", in: directory)
        let digest = sha256(of: "installer bytes")

        #expect(try await InstallerDigest.verify(file, against: digest))
        #expect(try await InstallerDigest.verify(file, against: "  \(digest.uppercased())\n"))
    }

    @Test func aDifferentDigestIsRefusedWithBothValues() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try write("installer bytes", named: "w.iso", in: directory)
        let wrong = sha256(of: "other bytes")

        do {
            try await InstallerDigest.verify(file, against: wrong)
            Issue.record("a different digest was accepted")
        } catch let failure as InstallerDigest.Failure {
            #expect(failure == .mismatch(expected: wrong, actual: sha256(of: "installer bytes")))
            #expect(failure.localizedDescription.contains(wrong) && failure.localizedDescription.contains("does not match"))
        }
    }

    @Test(arguments: [
        String(repeating: "a", count: 63), String(repeating: "a", count: 65), String(repeating: "g", count: 64),
        "sha256:" + String(repeating: "a", count: 57), String(repeating: "a", count: 32) + " " + String(repeating: "a", count: 32),
    ])
    func aMalformedDigestIsRefusedBeforeTheFileIsRead(text: String) async throws {
        let missing = URL(filePath: "/nonexistent/windows.iso")
        await #expect(throws: InstallerDigest.Failure.malformed) { try await InstallerDigest.verify(missing, against: text) }
        #expect(InstallerDigest.problem(in: text) == .malformed)
    }

    @Test func anEmptyDigestSkipsTheCheckAndNeverOpensTheFile() async throws {
        let missing = URL(filePath: "/nonexistent/windows.iso")
        #expect(try await InstallerDigest.verify(missing, against: "") == false)
        #expect(try await InstallerDigest.verify(missing, against: " \n") == false)
        #expect(InstallerDigest.problem(in: "") == nil && InstallerDigest.problem(in: String(repeating: "0", count: 64)) == nil)
    }

    @Test func aTypedMalformedDigestStopsTheSheetFromCreating() throws {
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let model = makeModel(scratch)
        model.localPath = "/Users/me/Win11_arm64.iso"

        model.expectedSHA256 = "not a digest"
        #expect(!model.canCreate)
        model.expectedSHA256 = sha256(of: "x")
        #expect(model.canCreate)
        model.expectedSHA256 = ""
        #expect(model.canCreate)
    }

    // MARK: Creating

    @Test func aMismatchMakesNoMachineAndSaysSo() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VMLibrary(machinesDirectory: directory.appending(path: "Machines"))
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let model = makeModel(scratch)
        model.localPath = try write("installer bytes", named: "w.iso", in: directory).path
        model.expectedSHA256 = sha256(of: "other bytes")

        #expect(!model.create(in: library), "the unchecked path refuses a machine that has a digest to check")
        #expect(!(await model.createAfterVerifying(in: library)))

        #expect(library.machines.isEmpty)
        #expect(model.creationError?.contains("does not match") == true)
        #expect(!model.isVerifying)
    }

    @Test func aMatchMakesTheMachineAndApprovesItsMedia() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VMLibrary(machinesDirectory: directory.appending(path: "Machines"))
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let model = makeModel(scratch)
        let iso = try write("installer bytes", named: "w.iso", in: directory).path
        let drivers = try write("drivers", named: "drivers.iso", in: directory).path
        model.localPath = iso
        model.driverDiscPath = drivers
        model.expectedSHA256 = sha256(of: "installer bytes")

        #expect(await model.createAfterVerifying(in: library))

        let machine = try #require(library.machines.first)
        #expect(machine.guest == .windows && machine.source == .local(iso) && machine.driverDiscPath == drivers)
        #expect(library.isApproved(HostPathGrant(.driverDisc, drivers, writable: false), for: machine.id))
        #expect(library.unapprovedHostPaths(for: machine.id).isEmpty)
        library.cancelJob(machine.id)
    }

    @Test func withoutAnExpectedDigestTheMachineIsMadeWithNoCheck() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VMLibrary(machinesDirectory: directory.appending(path: "Machines"))
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let model = makeModel(scratch)
        model.localPath = "/nonexistent/windows.iso"

        #expect(await model.createAfterVerifying(in: library), "an empty digest never opens the file")

        let machine = try #require(library.machines.first)
        library.cancelJob(machine.id)
        library.selectedController?.errorMessage = nil
    }

    @Test func aChangeToTheInstallerTheDigestOrTheGuestDuringTheCheckMakesNoMachine() async throws {
        let message = "The installer or its checksum changed while it was being checked. Try again."
        let changes: [@MainActor (NewMachineModel) -> Void] = [
            { $0.localPath = "/Users/me/Other.iso" },
            { $0.expectedSHA256 = String(repeating: "b", count: 64) },
            { $0.config.guest = .linux },
        ]
        for change in changes {
            let directory = try scratchDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let library = VMLibrary(machinesDirectory: directory.appending(path: "Machines"))
            let scratch = try ScratchDefaults()
            defer { scratch.cleanUp() }
            let model = makeModel(scratch)
            model.localPath = "/Users/me/Win11_arm64.iso"
            model.expectedSHA256 = String(repeating: "a", count: 64)
            model.verifyInstaller = { [weak model] _, _ in
                guard let model else { return false }
                #expect(model.isVerifying)
                change(model)
                return true
            }

            #expect(!(await model.createAfterVerifying(in: library)))

            #expect(library.machines.isEmpty)
            #expect(model.creationError == message)
            #expect(!model.isVerifying)
        }
    }

    @Test func aCheckThatChangesNothingMakesTheMachineFromTheCheckedChoices() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VMLibrary(machinesDirectory: directory.appending(path: "Machines"))
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let model = makeModel(scratch)
        let digest = String(repeating: "a", count: 64)
        model.localPath = "/Users/me/Win11_arm64.iso"
        model.expectedSHA256 = digest
        let checked = Checked()
        model.verifyInstaller = { file, text in
            checked.record((file.path, text))
            return true
        }

        #expect(await model.createAfterVerifying(in: library))

        #expect(checked.values.map(\.0) == ["/Users/me/Win11_arm64.iso"] && checked.values.map(\.1) == [digest])
        let machine = try #require(library.machines.first)
        #expect(machine.source == .local("/Users/me/Win11_arm64.iso"))
        #expect(model.creationError == nil)
        library.cancelJob(machine.id)
    }

    // MARK: The words

    @Test func theRequirementsPanelSaysExactlyThis() {
        #expect(
            WindowsRequirements.lines == [
                "Uses a private interface of the virtualization framework (performance-monitoring emulation). It is turned off in "
                    + "the Isolated and Hardened profiles and by the AllowPrivateInterfaces managed setting.",
                "Windows 11 Setup checks for a TPM 2.0 device. This machine has none: the app does not provide one and does not "
                    + "work around the check. Meeting Windows Setup's requirements and the licence terms is up to you.",
                "No suspend: a Windows machine can only be shut down or stopped.",
                "Each Windows installation needs its own licence. Insider Preview builds follow the Windows Insider Program's "
                    + "terms and expire; retail builds do not.",
                "Windows has no built-in driver for this machine's network device: networking needs a driver disc.",
                "Secure Boot is off.",
            ])
        #expect(WindowsRequirements.lines[0].contains(ManagedKey.allowPrivateInterfaces.rawValue))
    }

    @Test func noWindowsWordingMentionsAWayAroundWindowsSetupsChecks() {
        let forbidden = ["bypass", "LabConfig", "autounattend", "unattend", "BypassTPM", "registry"]
        let everything =
            WindowsRequirements.lines + [
                WindowsRequirements.installerNote, WindowsRequirements.expectedSHA256Note, WindowsRequirements.driverDiscNote,
            ]
        for text in everything {
            for word in forbidden {
                #expect(!text.localizedCaseInsensitiveContains(word), "\(word) in: \(text)")
            }
        }
    }
}

/// What a stand-in for the installer check was asked to check.
@MainActor
private final class Checked {
    private(set) var values: [(String, String)] = []
    func record(_ value: (String, String)) { values.append(value) }
}

extension VMConfig {
    fileprivate func withID(_ id: UUID) -> VMConfig {
        var copy = self
        copy.id = id
        return copy
    }
}
