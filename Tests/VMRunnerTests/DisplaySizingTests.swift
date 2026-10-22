import Foundation
import Testing

@testable import VMRunner

struct DisplayTests {
    @Test func fitsWindowAtOnePixelPerPointForLinux() {
        let config = VMConfig.new(name: "l", guest: .linux)
        let size = StartDisplay.size(for: config, window: CGSize(width: 1001, height: 653), restoring: false)
        #expect(size.width == 1000 && size.height == 652)
    }

    @Test func largeWindowsStartLinuxAtALegibleWidthWithTheWindowsAspectRatio() {
        let config = VMConfig.new(name: "l", guest: .linux)
        let size = StartDisplay.size(for: config, window: CGSize(width: 2312, height: 1388), restoring: false)
        #expect(size.width == 1280)
        #expect(abs(Double(size.width) / Double(size.height) - 2312.0 / 1388.0) < 0.01)
    }

    @Test func macOSGetsPixelsMatchingItsDensity() {
        var config = VMConfig.new(name: "m", guest: .macOS)
        config.pixelsPerInch = 144
        let size = StartDisplay.size(for: config, window: CGSize(width: 960, height: 600), restoring: false)
        #expect(size.width == 1920 && size.height == 1200, "macOS isn't capped: the guest scales by ppi")
    }

    @Test func fallsBackToConfiguredSizeWithoutAUsableWindow() {
        let config = VMConfig.new(name: "l", guest: .linux)
        let size = StartDisplay.size(for: config, window: nil, restoring: false)
        #expect(size.width == config.displayWidth && size.height == config.displayHeight)
    }

    @Test func suspendedMachineKeepsItsLastDisplaySize() {
        var config = VMConfig.new(name: "l", guest: .linux)
        config.lastDisplayWidth = 1100
        config.lastDisplayHeight = 700
        let size = StartDisplay.size(for: config, window: CGSize(width: 2000, height: 1000), restoring: true)
        #expect(size.width == 1100 && size.height == 700)
    }

    // MARK: What the firmware gets for realistic windows (a 1800 × 1100 point window on a Retina Mac)

    private let retinaWindow = CGSize(width: 1800, height: 1100)

    @Test(arguments: [1, 2])
    func aLargeWindowStartsLinuxAt1280WhateverThePixelsPerPoint(pixelsPerPoint: Int) {
        var config = VMConfig.new(name: "l", guest: .linux)
        config.pixelsPerPoint = pixelsPerPoint
        let size = StartDisplay.size(for: config, window: retinaWindow, restoring: false)
        #expect(size.width == 1280 && size.height == 782, "\(size)")
    }

    @Test func aRememberedSizeIsNotTheNextColdBootsStartingSize() {
        var config = VMConfig.new(name: "l", guest: .linux)
        config.lastDisplayWidth = 3200
        config.lastDisplayHeight = 2000
        let size = StartDisplay.size(for: config, window: retinaWindow, restoring: false)
        #expect(size.width == 1280 && size.height == 782, "the remembered size is only for restoring saved state")
    }

    @Test func aMachineWithoutAWindowSizeStartsLinuxAtItsDefaultSize() {
        let config = VMConfig.new(name: "l", guest: .linux)
        #expect(StartDisplay.size(for: config, window: CGSize(width: 100, height: 100), restoring: false) == (1280, 800))
    }

    @Test func macOSIsNotCappedWhateverIsRemembered() {
        var config = VMConfig.new(name: "m", guest: .macOS)
        config.lastDisplayWidth = 640
        config.lastDisplayHeight = 480
        let size = StartDisplay.size(for: config, window: retinaWindow, restoring: false)
        #expect(size.width == 3600 && size.height == 2200)
    }

    @Test func aSuspendedMachineRestoresAtItsStartSizeEvenWhenLargerThanTheCap() {
        var config = VMConfig.new(name: "l", guest: .linux)
        config.lastDisplayWidth = 3200
        config.lastDisplayHeight = 2000
        let size = StartDisplay.size(for: config, window: retinaWindow, restoring: true)
        #expect(size.width == 3200 && size.height == 2000, "saved state restores only into an identical configuration")
    }

    // MARK: A fixed size is capped at the start too, because the guest follows the window afterwards

    private struct FixedSize: CustomTestStringConvertible {
        var width: Int
        var height: Int
        var startWidth: Int
        var startHeight: Int
        var testDescription: String { "\(width)x\(height) starts at \(startWidth)x\(startHeight)" }
    }

    @Test(arguments: [
        FixedSize(width: 2560, height: 1600, startWidth: 1280, startHeight: 800),
        FixedSize(width: 1920, height: 1080, startWidth: 1280, startHeight: 720),
        FixedSize(width: 3200, height: 2000, startWidth: 1280, startHeight: 800),
        FixedSize(width: 7680, height: 4320, startWidth: 1280, startHeight: 720),
    ])
    private func aFixedSizeWiderThanTheCapStartsLinuxAtTheCapWithItsOwnAspectRatio(fixed: FixedSize) {
        var config = VMConfig.new(name: "l", guest: .linux)
        config.fitsWindowAtStart = false
        config.displayWidth = fixed.width
        config.displayHeight = fixed.height
        let size = StartDisplay.size(for: config, window: retinaWindow, restoring: false)
        #expect(size.width == fixed.startWidth && size.height == fixed.startHeight, "\(size)")
    }

    @Test func aFixedSizeIsKeptWhenTheUserAlsoTurnedFollowingOff() {
        var config = VMConfig.new(name: "l", guest: .linux)
        config.fitsWindowAtStart = false
        config.automaticallyReconfiguresDisplay = false
        config.displayWidth = 2560
        config.displayHeight = 1600
        let size = StartDisplay.size(for: config, window: retinaWindow, restoring: false)
        #expect(size.width == 2560 && size.height == 1600, "the guest keeps this size for the whole run, so it is what the user asked for")
    }

    @Test func aWideConfiguredSizeIsCappedWhenThereIsNoUsableWindow() {
        var config = VMConfig.new(name: "l", guest: .linux)
        config.displayWidth = 3200
        config.displayHeight = 2000
        let size = StartDisplay.size(for: config, window: nil, restoring: false)
        #expect(size.width == 1280 && size.height == 800)
    }

    @Test func macOSKeepsAFixedSizeWhateverItsWidth() {
        var config = VMConfig.new(name: "m", guest: .macOS)
        config.fitsWindowAtStart = false
        config.displayWidth = 2560
        config.displayHeight = 1600
        let size = StartDisplay.size(for: config, window: retinaWindow, restoring: false)
        #expect(size.width == 2560 && size.height == 1600)
    }

    @Test func aFixedSizeWithinTheCapIsLeftAsConfigured() {
        var config = VMConfig.new(name: "l", guest: .linux)
        config.fitsWindowAtStart = false
        config.displayWidth = 1111
        config.displayHeight = 701
        let size = StartDisplay.size(for: config, window: retinaWindow, restoring: false)
        #expect(size.width == 1111 && size.height == 701)
    }
}
