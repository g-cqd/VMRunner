import Foundation
import Testing
import Virtualization

@testable import VMRunner

/// The addresses each vendor choice makes, and the default every existing machine keeps.
struct MACVendorTests {
    @Test(arguments: MACVendor.allCases)
    func everyAddressIsAUnicastAddressTheFrameworkAccepts(vendor: MACVendor) throws {
        for _ in 0..<64 {
            let text = vendor.makeAddress()
            let address = try #require(VZMACAddress(string: text), "\(text)")
            #expect(address.isUnicastAddress)
            #expect(text == text.lowercased() && text.count == 17)
            if let prefix = vendor.prefix {
                #expect(text.hasPrefix(prefix.map { [$0].hexString }.joined(separator: ":") + ":"))
                #expect(address.isUniversallyAdministeredAddress)
            } else {
                #expect(address.isLocallyAdministeredAddress)
            }
        }
    }

    @Test func thePrefixesAreTheRegisteredOnes() {
        #expect(MACVendor.apple.prefix == [0x00, 0x03, 0x93])
        #expect(MACVendor.intel.prefix == [0x00, 0x1B, 0x21])
        #expect(MACVendor.realtek.prefix == [0x00, 0xE0, 0x4C])
        #expect(MACVendor.locallyAdministered.prefix == nil)
    }

    @Test func aNewMachineAndAConfigWrittenBeforeTheChoiceKeepTheFrameworksKindOfAddress() throws {
        #expect(VMConfig.new(name: "m", guest: .linux).macVendor == .locallyAdministered)
        let old =
            #"{"id":"3B873409-1F62-435C-A557-0040D55FBE19","name":"legacy","guest":"linux","cpuCount":2,"memoryMiB":2048,"diskGiB":32}"#
        #expect(try VMConfig.decode(from: Data(old.utf8)).macVendor == .locallyAdministered)
    }
}

/// A start that has to make an address uses the machine's vendor.
@MainActor
struct MACVendorStartTests {
    @Test func anAutomaticAddressTakesTheMachinesVendorPrefix() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        var config = rig.config
        config.macVendor = .intel
        config.macAddress = nil
        rig.library.update(config)
        let guest = rig.factory.add()
        await rig.start()
        #expect(rig.config.macAddress?.hasPrefix("00:1b:21:") == true)
        guest.powerOff()
        rig.expectReleased()
    }
}
