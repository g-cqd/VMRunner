import AppKit
import Foundation
import Testing

@testable import VMRunner

struct PreferencesDomainTests {
    @Test func aRunWithoutADataDirectoryUsesTheStandardDomain() {
        #expect(PreferencesDomain.suiteName(environment: [:], appIdentifier: "studio.aemi.VMRunner") == nil)
        #expect(PreferencesDomain.suiteName(environment: ["VMRUNNER_DATA_DIR": ""], appIdentifier: "studio.aemi.VMRunner") == nil)
    }

    @Test func aRunWithADataDirectoryGetsADomainOfItsOwn() {
        #expect(
            PreferencesDomain.suiteName(environment: ["VMRUNNER_DATA_DIR": "/tmp/run"], appIdentifier: "studio.aemi.VMRunner")
                == "studio.aemi.VMRunner.data-directory-override")
    }
}

@MainActor
struct WindowStateTests {
    @Test func aWindowCanBeToldToSaveNeitherItsFrameNorItsState() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        _ = window.setFrameAutosaveName("VMRunnerTests-\(UUID().uuidString)")
        window.isRestorable = true
        window.stopSavingFrameAndState()
        #expect(window.frameAutosaveName.isEmpty)
        #expect(!window.isRestorable)
    }

    @Test func aSplitViewDeepInTheWindowStopsSavingItsWidths() {
        let root = NSView()
        let wrapper = NSView()
        let outer = NSSplitView()
        outer.autosaveName = "VMRunnerTests-outer"
        let inner = NSView()
        let deeper = NSSplitView()
        deeper.autosaveName = "VMRunnerTests-deeper"
        root.addSubview(wrapper)
        wrapper.addSubview(outer)
        outer.addSubview(inner)
        inner.addSubview(deeper)
        #expect(outer.autosaveName == "VMRunnerTests-outer", "the precondition")
        #expect(deeper.autosaveName == "VMRunnerTests-deeper", "the precondition")
        root.stopSavingSplitViewState()
        #expect((outer.autosaveName ?? "").isEmpty)
        #expect((deeper.autosaveName ?? "").isEmpty)
    }
}

struct LaunchDefaultsTests {
    @Test func theLaunchDefaultIsRegisteredInMemoryAndNeverWritten() throws {
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        let suite = scratch.defaults
        #expect(suite.object(forKey: PreferencesDomain.launchKey) == nil)
        PreferencesDomain.registerLaunchDefaults(on: suite)
        #expect(suite.bool(forKey: PreferencesDomain.launchKey))
        #expect(suite.persistentDomain(forName: scratch.name)?[PreferencesDomain.launchKey] == nil, "registered, not written")
    }
}

@MainActor
struct AppSettingTests {
    @Test func theKeysAreTheOnesEveryVersionHasStored() {
        #expect(
            AppSetting.allCases.map(\.rawValue) == [
                "hidesToolbarInFullScreen", "keepsRestoreImages", "holdsLatencyActivity", "ipswDeviceIdentifier", "runsControlService",
            ])
        #expect(LatencyActivity.settingKey == AppSetting.holdsLatencyActivity.rawValue)
        #expect(NewMachineModel.deviceDefaultsKey == AppSetting.ipswDeviceIdentifier.rawValue)
    }
}
