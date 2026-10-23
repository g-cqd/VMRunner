import Foundation
import Testing

@testable import VMRunner

/// A Linux machine's provisioning spec path: stored with a tolerant decode, bounded like every host path, in use only for a
/// Linux guest without its installer attached, and approved like the installer image.
struct ProvisioningSpecPathTests {
    private func machine(_ guest: GuestOS = .linux, spec: String = "/Users/me/machine.yaml") -> VMConfig {
        var config = VMConfig.new(name: "m", guest: guest)
        config.provisioningSpecPath = spec
        return config
    }

    @Test
    func theSpecIsEmptyForANewMachineAndForAConfigWrittenBeforeItExisted() throws {
        for guest in GuestOS.allCases { #expect(VMConfig.new(name: "n", guest: guest).provisioningSpecPath.isEmpty) }
        let old =
            #"{"id":"3B873409-1F62-435C-A557-0040D55FBE19","name":"legacy","guest":"linux","cpuCount":2,"memoryMiB":2048,"diskGiB":32}"#
        #expect(try VMConfig.decode(from: Data(old.utf8)).provisioningSpecPath.isEmpty)
    }

    @Test
    func thePathIsStoredAndReadBack() throws {
        #expect(try VMConfig.decode(from: machine().encoded()).provisioningSpecPath == "/Users/me/machine.yaml")
    }

    @Test(arguments: ["machine.yaml", "./machine.yaml", "/" + String(repeating: "a", count: EditorLimits.maxPathLength)])
    func aRelativeOrOverlongPathIsRefusedWhereTheConfigIsRead(path: String) {
        #expect(throws: DecodingError.self) { try VMConfig.decode(from: machine(spec: path).encoded()) }
    }

    @Test
    func theSpecIsInUseOnlyForALinuxGuestWithoutItsInstallerAttached() {
        #expect(machine().activeProvisioningSpecPath == "/Users/me/machine.yaml")
        #expect(machine(.macOS).activeProvisioningSpecPath == nil)
        #expect(machine(spec: "").activeProvisioningSpecPath == nil)
        var installing = machine()
        installing.installerISO = "/Users/me/installer.iso"
        #expect(installing.activeProvisioningSpecPath == nil, "the installer's live system would run the steps too")
        installing.installerAttached = false
        #expect(installing.activeProvisioningSpecPath == "/Users/me/machine.yaml")
    }

    @Test
    func theSpecInUseNeedsTheUsersApprovalAndIsReadOnly() {
        #expect(machine().hostGrants == [HostPathGrant(.provisioningSpec, "/Users/me/machine.yaml", writable: false)])
        #expect(machine(.macOS).hostGrants.isEmpty)
        #expect(machine(spec: "").hostGrants.isEmpty)
        let grant = HostPathGrant(.provisioningSpec, "/Users/me/machine.yaml", writable: false)
        #expect(!HostPathGrant(.installer, "/Users/me/machine.yaml", writable: false).covers(grant), "another kind does not cover it")
        #expect(grant.summary == "/Users/me/machine.yaml (provisioning spec and the scripts it names, read-only)")
    }
}
