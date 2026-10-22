import Foundation
import Testing

@testable import VMRunner

/// A profile never turns Secure Boot on for an image whose boot chain is unsigned (Alpine), and the editor and the exposure
/// summary say so.
struct SecureBootPostureTests {
    private static func machine(_ guest: GuestOS, imageSupports: Bool) -> VMConfig {
        var config = VMConfig.new(name: "x", guest: guest)
        config.imageSupportsSecureBoot = imageSupports
        return config
    }

    @Test(arguments: GuestOS.allCases, SecurityProfile.allCases)
    func aProfileSetsSecureBootOnlyWhereGuestHostAndImageAllowIt(guest: GuestOS, profile: SecurityProfile) {
        for imageSupports in [true, false] {
            for hostSupports in [true, false] {
                let config = Self.machine(guest, imageSupports: imageSupports)
                let applied = config.applying(profile, hostSupportsSecureBoot: hostSupports)

                let closed = profile == .isolated || profile == .hardened
                let expected = closed && guest == .linux && imageSupports && hostSupports
                #expect(applied.secureBoot == expected, "\(guest) \(profile) image \(imageSupports) host \(hostSupports)")
                #expect(applied.posture.secureBoot == expected)
            }
        }
    }

    @Test(arguments: SecurityProfile.allCases, [true, false])
    func everyProfileReadsBackAsItselfWhateverTheImage(profile: SecurityProfile, imageSupports: Bool) {
        let applied = Self.machine(.linux, imageSupports: imageSupports).applying(profile)
        #expect(applied.detectedProfile == profile)
    }

    @Test(arguments: [SecurityProfile.isolated, .hardened])
    func aProfileTurnsSecureBootOffAgainOnAnImageThatCannotUseIt(profile: SecurityProfile) {
        var config = Self.machine(.linux, imageSupports: false)
        config.secureBoot = true
        #expect(!config.applying(profile, hostSupportsSecureBoot: true).secureBoot)
    }

    @Test func availabilityNamesTheFirstThingInTheWay() {
        #expect(Self.machine(.macOS, imageSupports: true).secureBootAvailability(hostSupports: true) == .notApplicable)
        #expect(Self.machine(.linux, imageSupports: true).secureBootAvailability(hostSupports: true) == .available)
        #expect(Self.machine(.linux, imageSupports: true).secureBootAvailability(hostSupports: false) == .hostTooOld)
        #expect(Self.machine(.linux, imageSupports: false).secureBootAvailability(hostSupports: true) == .imageUnsupported)
        #expect(Self.machine(.linux, imageSupports: false).secureBootAvailability(hostSupports: false) == .imageUnsupported)
    }

    @Test func theSwitchIsLockedWithAReasonOnAnImageThatCannotUseIt() {
        var config = Self.machine(.linux, imageSupports: false)
        #expect(!config.secureBootIsEditable)
        #expect(config.secureBootNote.contains("no signed bootloader"))
        #expect(!config.secureBootNote.contains("Turn it off"))

        config.secureBoot = true
        #expect(config.secureBootIsEditable, "a switch that is already on can still be turned off")
        #expect(config.secureBootNote.contains("Turn it off"))
    }

    @Test func theExposureSummarySaysWhySecureBootIsOff() throws {
        let alpine = Self.machine(.linux, imageSupports: false).applying(.isolated, hostSupportsSecureBoot: true)
        let text = try #require(alpine.exposures.first { $0.text.hasPrefix("Secure Boot") }).text
        #expect(text.contains("stays off") && text.contains("no profile can turn it on"))

        let ubuntu = Self.machine(.linux, imageSupports: true).applying(.isolated, hostSupportsSecureBoot: true)
        #expect(ubuntu.exposures.contains { $0.text == "Secure Boot is enforced." })

        var stuckOn = Self.machine(.linux, imageSupports: false)
        stuckOn.secureBoot = true
        #expect(stuckOn.exposures.contains { $0.text.contains("so it will not start") })

        #expect(!Self.machine(.macOS, imageSupports: false).exposures.contains { $0.text.hasPrefix("Secure Boot") })
    }
}

struct SecureBootRecordingTests {
    @Test(arguments: LinuxCatalog.images)
    func setupRecordsWhatEachCatalogImageCanDo(image: LinuxImage) {
        var config = VMConfig.new(name: "x", guest: .linux)
        config.source = .linuxCatalog(id: image.id)
        config.recordCatalogImageCapabilities()
        #expect(config.imageSupportsSecureBoot == image.supportsSecureBoot)
    }

    @Test func aFileOfUnknownCapabilityKeepsToday() {
        var config = VMConfig.new(name: "x", guest: .linux)
        config.source = .local("/tmp/some.iso")
        config.recordCatalogImageCapabilities()
        #expect(config.imageSupportsSecureBoot)

        config.source = .linuxCatalog(id: "no-such-image")
        config.recordCatalogImageCapabilities()
        #expect(config.imageSupportsSecureBoot)
    }

    @Test func aMachineStoredWithoutTheFieldKeepsSecureBootAvailable() throws {
        let old =
            #"{"id":"3B873409-1F62-435C-A557-0040D55FBE19","name":"legacy","guest":"linux","cpuCount":2,"memoryMiB":2048,"#
            + #""diskGiB":32,"secureBoot":true}"#
        let config = try VMConfig.decode(from: Data(old.utf8))
        #expect(config.imageSupportsSecureBoot)
        #expect(config.secureBoot)
    }

    @Test func theFactSurvivesAStoreAndLoad() throws {
        var config = VMConfig.new(name: "alpine", guest: .linux)
        config.imageSupportsSecureBoot = false
        #expect(try VMConfig.decode(from: config.encoded()).imageSupportsSecureBoot == false)
    }
}
