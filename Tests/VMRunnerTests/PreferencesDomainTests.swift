import AppKit
import Foundation
import Testing

@testable import VMRunner

struct PreferencesDomainTests {
    @Test func aRunWithoutADataDirectoryUsesTheStandardDomain() {
        #expect(PreferencesDomain.suiteName(environment: [:], appIdentifier: "com.example.VMRunner") == nil)
        #expect(PreferencesDomain.suiteName(environment: ["VMRUNNER_DATA_DIR": ""], appIdentifier: "com.example.VMRunner") == nil)
    }

    @Test func aRunWithADataDirectoryGetsADomainOfItsOwn() {
        #expect(
            PreferencesDomain.suiteName(environment: ["VMRUNNER_DATA_DIR": "/tmp/run"], appIdentifier: "com.example.VMRunner")
                == "com.example.VMRunner.data-directory-override")
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
}

struct LaunchDefaultsTests {
    @Test func theLaunchDefaultIsRegisteredInMemoryAndNeverWritten() throws {
        let name = "LaunchDefaultsTests-\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: name))
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        #expect(suite.object(forKey: PreferencesDomain.launchKey) == nil)
        PreferencesDomain.registerLaunchDefaults(on: suite)
        #expect(suite.bool(forKey: PreferencesDomain.launchKey))
        #expect(suite.persistentDomain(forName: name)?[PreferencesDomain.launchKey] == nil, "registered, not written")
    }
}
