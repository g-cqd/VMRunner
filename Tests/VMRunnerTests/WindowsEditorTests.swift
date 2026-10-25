import Foundation
import Testing

@testable import VMRunner

/// What the machine editor shows a Windows machine, how the driver disc is picked and approved, what the security summary says
/// about it, and what the help says about Windows. The editor's own rules are pure (`GuestEditorRows`, `EditorSection.visible`),
/// so the tests read them directly.
@MainActor
struct WindowsEditorTests {
    private func windows() -> VMConfig { VMConfig.new(name: "w", guest: .windows, hostCPUs: 16, hostMemoryGiB: 64) }

    // MARK: Which sections and rows each guest gets

    @Test func aWindowsMachineShowsTheSectionsItHasAndNotTheOthers() {
        #expect(
            EditorSection.visible(for: windows()) == [
                .general, .security, .compute, .storage, .installer, .display, .input, .audio, .network, .identity, .sharing,
                .hostInfo, .devices, .agentAccess, .snapshots,
            ])
        var filtered = windows()
        filtered.networkMode = .filtered
        #expect(EditorSection.visible(for: filtered).contains(.networkPolicy))
    }

    @Test func linuxAndMacOSKeepTheirSections() {
        let linux = EditorSection.visible(for: VMConfig.new(name: "l", guest: .linux))
        #expect(linux.contains(.installer) && linux.contains(.provisioning) && !linux.contains(.boot))
        let mac = EditorSection.visible(for: VMConfig.new(name: "m", guest: .macOS))
        #expect(mac.contains(.boot) && !mac.contains(.installer) && !mac.contains(.provisioning))
    }

    @Test func aWindowsMachineHidesEveryRowThatBelongsToAnotherGuest() {
        let rows = GuestEditorRows(.windows)
        #expect(!rows.graphicsDevice && !rows.pixelDensity && !rows.linuxDisplayNote && !rows.pixelsPerPoint)
        #expect(!rows.pointingDevice && !rows.serialConsole && !rows.clipboardAndRosetta && !rows.diskInterface)
        #expect(!rows.secureBoot && !rows.allowSuspend && !rows.provisioning && !rows.firstBoot)
        #expect(rows.installer && rows.driverDisc && rows.nestedVirtualization && rows.windowsNotes)
    }

    @Test func linuxAndMacOSKeepTheirRows() {
        let linux = GuestEditorRows(.linux)
        #expect(linux.graphicsDevice && linux.pixelsPerPoint && linux.serialConsole && linux.clipboardAndRosetta)
        #expect(linux.diskInterface && linux.secureBoot && linux.allowSuspend && linux.nestedVirtualization && linux.installer)
        #expect(!linux.driverDisc && !linux.windowsNotes && !linux.pointingDevice && !linux.pixelDensity)
        let mac = GuestEditorRows(.macOS)
        #expect(mac.pixelDensity && mac.pointingDevice && mac.serialConsole && mac.allowSuspend && mac.firstBoot)
        #expect(!mac.nestedVirtualization && !mac.installer && !mac.driverDisc && !mac.secureBoot && !mac.clipboardAndRosetta)
    }

    @Test(arguments: GuestOS.allCases)
    func theRowsAgreeWithWhatTheModelAcceptsAndRefuses(guest: GuestOS) {
        let config = VMConfig.new(name: "g", guest: guest)
        let rows = GuestEditorRows(guest)
        #expect(rows.allowSuspend == (config.guestSuspendReason == nil))
        #expect(rows.secureBoot == (config.secureBootAvailability() != .notApplicable))
        var attached = config
        attached.installerISO = "/Users/me/installer.iso"
        attached.driverDiscPath = "/Users/me/drivers.iso"
        #expect((attached.attachedInstallerPath != nil) == rows.installer)
        #expect((attached.attachedDriverDiscPath != nil) == rows.driverDisc)
    }

    // MARK: The driver disc

    private func makeLibrary(in directory: URL) -> VMLibrary {
        VMLibrary(machinesDirectory: directory.appending(path: "Machines"), approvalsFile: directory.appending(path: "Approvals.json"))
    }

    @Test func theDriverDiscPickerStoresThePathAndApprovesItReadOnly() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = makeLibrary(in: directory)
        library.load()
        let config = windows()
        try library.add(config)
        let editor = ConfigEditorModel(id: config.id, library: library)

        editor.importFile(URL(filePath: "/Users/me/drivers.iso"), for: .driverDisc)

        let saved = try #require(library.machine(config.id))
        #expect(saved.driverDiscPath == "/Users/me/drivers.iso")
        #expect(saved.hostGrants == [HostPathGrant(.driverDisc, "/Users/me/drivers.iso", writable: false)])
        #expect(library.unapprovedHostPaths(for: config.id).isEmpty)
        #expect(editor.alertMessage == nil)
    }

    @Test func aDriverDiscInsideTheMachinesFolderIsRefusedAndNothingIsStored() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = makeLibrary(in: directory)
        library.load()
        let config = windows()
        try library.add(config)
        let editor = ConfigEditorModel(id: config.id, library: library)
        let inside = library.bundle(config.id).disk

        editor.importFile(inside, for: .driverDisc)

        #expect(try #require(library.machine(config.id)).driverDiscPath == nil)
        #expect(editor.alertMessage?.contains(inside.path) == true)
    }

    // MARK: The security summary

    @Test func aWindowsMachineUnderAClosingProfileIsToldItWillNotStart() {
        let config = windows()
        #expect(WindowsRequirements.profileNote(for: config) == nil)
        #expect(WindowsRequirements.profileNote(for: config.applying(.contained)) == nil)
        for profile in [SecurityProfile.isolated, .hardened] {
            let note = WindowsRequirements.profileNote(for: config.applying(profile))
            #expect(note?.contains(profile.label) == true && note?.contains("will not start") == true)
        }
        #expect(WindowsRequirements.profileNote(for: VMConfig.new(name: "l", guest: .linux).applying(.isolated)) == nil)
    }

    @Test func theExposureSummaryOfAWindowsMachineSaysWhatIsSoOfIt() {
        let texts = windows().exposures.map(\.text)
        #expect(texts.contains { $0.hasPrefix("Private interface: performance-monitoring emulation") })
        #expect(texts.contains("Secure Boot is off: unsigned bootloaders and kernels can run."))
        #expect(texts.contains("No memory snapshot is written to disk."))
        #expect(!texts.contains { $0.hasPrefix("Suspending writes") })
    }

    @Test func aSettingThatOnlyAnotherGuestActsOnIsNotListedForWindows() {
        var config = windows()
        config.sharesClipboard = true
        config.rosetta = true
        config.serialConsole = true
        config.provisioningSpecPath = "/Users/me/machine.yaml"
        config.provisioning.enabled = true
        config.bootIntoRecovery = true

        let texts = config.exposures.map(\.text)
        #expect(!texts.contains { $0.contains("Clipboard") || $0.contains("Rosetta") || $0.contains("serial console") })
        #expect(!texts.contains { $0.contains("Provisioning") || $0.contains("first-boot") })
        let posture = config.posture
        #expect(!posture.clipboard && !posture.rosetta && !posture.serialConsole && !posture.provisioning)
        #expect(!posture.recovery && !posture.autoLogin && !posture.remoteLogin && !posture.secureBoot)
    }

    @Test func theSecureBootLineIsStillOnlyForGuestsThatBootThroughEFI() {
        #expect(VMConfig.new(name: "l", guest: .linux).exposures.contains { $0.text.hasPrefix("Secure Boot is") })
        #expect(!VMConfig.new(name: "m", guest: .macOS).exposures.contains { $0.text.hasPrefix("Secure Boot is") })
    }

    @Test func theIsolatedProfileSummaryNamesTheDriverDisc() {
        #expect(SecurityProfile.isolated.summary.contains("driver disc"))
        #expect(HelpTopic.securityProfiles.entry.paragraphs.joined(separator: " ").contains("driver disc"))
    }

    // MARK: The help

    private func text(of topic: HelpTopic) -> String { (topic.entry.paragraphs + topic.entry.advanced).joined(separator: " ") }

    @Test func theWindowsTopicStatesWhatTheSheetDoes() {
        let entry = HelpTopic.windowsMachines.entry
        let body = text(of: .windowsMachines)
        #expect(entry.area == .start && entry.title == "Windows guests (experimental)")
        for line in WindowsRequirements.lines { #expect(body.contains(line), "\(line)") }
        for phrase in ["never downloads", "Expected SHA-256", "driver disc", "64 GiB", "read-only USB drive", "experimental"] {
            #expect(body.localizedCaseInsensitiveContains(phrase), "missing: \(phrase)")
        }
        #expect(HelpCatalog.search("windows").contains(.windowsMachines))
        #expect(
            HelpTopic.limits.entry.related.contains(.windowsMachines) && HelpTopic.guestSystems.entry.related.contains(.windowsMachines))
    }

    @Test func noHelpTextSaysWindowsIsNotSupportedAnyMore() {
        for topic in HelpTopic.allCases {
            let body = text(of: topic)
            #expect(!body.contains("Windows is not supported") && !body.contains("No Windows guests"), "\(topic.rawValue)")
        }
    }

    @Test func theDeveloperDefaultsAreDocumentedBesideEachOther() {
        let body = text(of: .privateInterfaces)
        #expect(body.contains(PrivateInterfacesKillSwitch.defaultsKey) && body.contains(WindowsStartsWithoutPMU.defaultsKey))
        #expect(body.contains("explicit true"))
    }

    @Test func noWindowsWordingMentionsAWayAroundWindowsSetupsChecks() {
        let forbidden = ["bypass", "LabConfig", "autounattend", "unattend", "BypassTPM", "registry"]
        var texts = [WindowsRequirements.sharingNote, WindowsRequirements.networkDriver]
        texts += [WindowsRequirements.profileNote(for: windows().applying(.isolated)) ?? ""]
        texts += HelpTopic.allCases.filter { text(of: $0).contains("Windows") }.map { text(of: $0) + $0.summary + $0.title }
        #expect(texts.count > 4)
        for text in texts {
            for word in forbidden {
                #expect(!text.localizedCaseInsensitiveContains(word), "\(word) in: \(text.prefix(80))")
            }
        }
    }
}
