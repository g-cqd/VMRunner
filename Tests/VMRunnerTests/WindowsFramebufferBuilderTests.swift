import Foundation
import PrivateInterfaces
import Synchronization
import Testing
import Virtualization

@testable import VMRunner

@MainActor
struct WindowsFramebufferBuilderTests {
    private func bundle(in directory: URL) throws -> VMBundle {
        let bundle = VMBundle(url: directory)
        try Data(count: 1 << 20).write(to: bundle.disk)
        try VZGenericMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifier)
        return bundle
    }

    @Test func thePreparedBootPathUsesReadOnlyBootstrapAndItsOwnFirmwareStoreAndFixedGraphics() throws {
        guard #available(macOS 27.0, *) else { return }
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try bundle(in: directory)
        let media = try WindowsBootMedia.prepareSynchronously(in: bundle)
        let source = WindowsDisplaySession(variables: media.variables, token: media.token)
        let calls = Mutex(0)
        let settings = WindowsStartSettings(
            decision: .allowed,
            applyPerformanceMonitoring: { _ in
                Issue.record("standalone PMU must not be called")
                return .available
            },
            startsWithoutPerformanceMonitoring: false,
            applyFramebufferBoot: { _ in
                calls.withLock { $0 += 1 }
                return .available
            }, bootMedia: media)
        let config = VMConfig.new(name: "test", guest: .windows)
        let built = try ConfigurationBuilder.assemble(
            config, bundle: bundle, display: (4096, 2160), customGPU: source, windows: settings
        ).configuration
        #expect(calls.withLock { $0 } == 1)
        #expect(built.storageDevices.count == 2)
        #expect(built.storageDevices.first is VZUSBMassStorageDeviceConfiguration)
        #expect((built.storageDevices.first?.attachment as? VZDiskImageStorageDeviceAttachment)?.isReadOnly == true)
        #expect(built.storageDevices.last is VZVirtioBlockDeviceConfiguration)
        #expect(built.customVirtioDevices.count == 1 && built.customVirtioDevices.first?.deviceID == 0x7f)
        #expect((built.bootLoader as? VZEFIBootLoader)?.variableStore?.url == media.variables)
        let graphics = try #require(built.graphicsDevices.first as? VZVirtioGraphicsDeviceConfiguration)
        #expect(graphics.scanouts.first?.widthInPixels == 1920 && graphics.scanouts.first?.heightInPixels == 1200)
        #expect(source.prefersFrameworkOverlay && !source.requestDisplaySize(width: 1280, height: 800))
        #expect(WindowsFrameOverlay().hitTest(.zero) == nil)
    }

    @Test func theDiagnosticBypassCannotRelaxFramebufferBootPolicyOrReadBackFailures() throws {
        guard #available(macOS 27.0, *) else { return }
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try bundle(in: directory)
        let media = try WindowsBootMedia.prepareSynchronously(in: bundle)
        let source = WindowsDisplaySession(variables: media.variables, token: media.token)
        let config = VMConfig.new(name: "test", guest: .windows)
        for decision in [
            PrivateCapabilityPolicy.Decision.allowed, .denied(.killSwitch), .denied(.managedKey), .denied(.profile(.hardened)),
        ] {
            let calls = Mutex(0)
            let settings = WindowsStartSettings(
                decision: decision,
                applyPerformanceMonitoring: { _ in
                    Issue.record("standalone PMU called")
                    return .available
                },
                startsWithoutPerformanceMonitoring: true,
                applyFramebufferBoot: { _ in
                    calls.withLock { $0 += 1 }
                    return .unavailable(.readBackMismatch(selector: "test"))
                }, bootMedia: media)
            #expect(throws: SetupError.self) {
                try ConfigurationBuilder.assemble(config, bundle: bundle, customGPU: source, windows: settings)
            }
            #expect(calls.withLock { $0 } == (decision.isAllowed ? 1 : 0))
        }
    }

    @Test func aMissingDisplayOrUnverifiedStorageControllerCannotEnableThePair() throws {
        guard #available(macOS 27.0, *) else { return }
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try bundle(in: directory)
        let media = try WindowsBootMedia.prepareSynchronously(in: bundle)
        let source = WindowsDisplaySession(variables: media.variables, token: media.token)
        let settings = WindowsStartSettings(
            decision: .allowed, applyPerformanceMonitoring: { _ in .available }, startsWithoutPerformanceMonitoring: true,
            applyFramebufferBoot: { _ in
                Issue.record("unprepared boot enabled")
                return .available
            }, bootMedia: media)
        var config = VMConfig.new(name: "test", guest: .windows)
        #expect(throws: SetupError.self) {
            try ConfigurationBuilder.assemble(config, bundle: bundle, windows: settings)
        }
        config.diskInterface = .nvme
        #expect(throws: SetupError.self) {
            try ConfigurationBuilder.assemble(config, bundle: bundle, customGPU: source, windows: settings)
        }
    }

    @Test func legacyResizeSettingsCannotChangeTheBootstrapMode() {
        var config = VMConfig.new(name: "test", guest: .windows)
        config.fitsWindowAtStart = true
        config.automaticallyReconfiguresDisplay = true
        config.displayWidth = 4096
        config.displayHeight = 2160
        config.lastDisplayWidth = 2560
        config.lastDisplayHeight = 1600
        for restoring in [true, false] {
            let decision = StartDisplay.decide(for: config, window: CGSize(width: 900, height: 600), restoring: restoring)
            #expect(decision.width == 1920 && decision.height == 1200 && decision.rememberedSizeIgnored)
        }
    }
}
