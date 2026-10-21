import Foundation
import Testing

@testable import VMRunner

struct DisplayTests {
    @Test func fitsWindowAtOnePixelPerPointForLinux() {
        let config = VMConfig.new(name: "l", guest: .linux)
        let size = ConfigurationBuilder.displaySize(for: config, windowSize: CGSize(width: 1001, height: 653), restoring: false)
        #expect(size.width == 1000 && size.height == 652)
    }

    @Test func largeWindowsStartLinuxAtALegibleWidthWithTheWindowsAspectRatio() {
        let config = VMConfig.new(name: "l", guest: .linux)
        let size = ConfigurationBuilder.displaySize(for: config, windowSize: CGSize(width: 2312, height: 1388), restoring: false)
        #expect(size.width == 1280)
        #expect(abs(Double(size.width) / Double(size.height) - 2312.0 / 1388.0) < 0.01)
    }

    @Test func macOSGetsPixelsMatchingItsDensity() {
        var config = VMConfig.new(name: "m", guest: .macOS)
        config.pixelsPerInch = 144
        let size = ConfigurationBuilder.displaySize(for: config, windowSize: CGSize(width: 960, height: 600), restoring: false)
        #expect(size.width == 1920 && size.height == 1200, "macOS isn't capped: the guest scales by ppi")
    }

    @Test func fallsBackToConfiguredSizeWithoutAUsableWindow() {
        let config = VMConfig.new(name: "l", guest: .linux)
        let size = ConfigurationBuilder.displaySize(for: config, windowSize: nil, restoring: false)
        #expect(size.width == config.displayWidth && size.height == config.displayHeight)
    }

    @Test func suspendedMachineKeepsItsLastDisplaySize() {
        var config = VMConfig.new(name: "l", guest: .linux)
        config.lastDisplayWidth = 1100
        config.lastDisplayHeight = 700
        let size = ConfigurationBuilder.displaySize(for: config, windowSize: CGSize(width: 2000, height: 1000), restoring: true)
        #expect(size.width == 1100 && size.height == 700)
    }
}
