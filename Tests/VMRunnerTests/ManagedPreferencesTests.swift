import Foundation
import Testing

@testable import VMRunner

/// Managed preferences (ADR-0013): only a forced value is policy, a forced value of the wrong type restricts, and what the
/// policy allows is left alone.
struct ManagedPreferencesTests {
    private func forced(_ values: [String: Any]) -> ManagedPreferences {
        ManagedPreferences(forcedValue: { values[$0] })
    }

    private func openMachine() -> VMConfig {
        var config = VMConfig.new(name: "m", guest: .linux)
        config.sharedFolders = [SharedFolder(path: "/tmp/a")]
        config.sharesClipboard = true
        config.audioInput = true
        config.allowsSuspend = true
        config.hostInfo.battery = true
        config.maxRuntimeMinutes = 0
        return config
    }

    @Test func nothingForcedChangesNothing() {
        let config = openMachine()
        #expect(ManagedPreferences(forcedValue: { _ in nil }).clamp(config) == config)
    }

    @Test func everyForcedRestrictionIsApplied() {
        let policy = forced([
            "AllowSharedFolders": false, "AllowClipboardSharing": false, "AllowMicrophone": false, "AllowSuspend": false,
            "AllowHostInformation": false, "RequireDisposableMachines": true, "MaxRuntimeMinutes": 60,
        ])
        let clamped = policy.clamp(openMachine())
        #expect(clamped.sharedFolders.isEmpty && !clamped.sharesClipboard && !clamped.audioInput && !clamped.allowsSuspend)
        #expect(clamped.hostInfo.isEmpty && clamped.ephemeral && clamped.maxRuntimeMinutes == 60)
    }

    @Test func whatThePolicyAllowsIsKept() {
        var config = openMachine()
        config.maxRuntimeMinutes = 30
        let policy = forced(["AllowSharedFolders": true, "RequireDisposableMachines": false, "MaxRuntimeMinutes": 60])
        #expect(policy.clamp(config) == config, "allowed stays, and a shorter limit of the user's own is kept")
    }

    @Test func aForcedValueOfTheWrongTypeRestricts() {
        let policy = forced(["AllowMicrophone": "yes", "RequireDisposableMachines": "no", "MaxRuntimeMinutes": "lots"])
        let clamped = policy.clamp(openMachine())
        #expect(!clamped.audioInput && clamped.ephemeral)
        #expect(clamped.maxRuntimeMinutes == EditorLimits.runtimeStepMinutes)
    }

    @Test func aForcedRuntimeOfZeroSetsNoLimitAndLocksNothing() {
        let policy = forced(["MaxRuntimeMinutes": 0])
        #expect(policy.maxRuntimeMinutes == nil && !policy.isLocked(.maxRuntimeMinutes))
        var config = openMachine()
        #expect(policy.clamp(config) == config, "a machine without a limit keeps none")
        config.maxRuntimeMinutes = 120
        #expect(policy.clamp(config) == config, "and one with a limit keeps its own")
    }

    @Test func aRealNumberFromAProfileCountsAsAWholeNumber() {
        // A profile delivers <real> as an NSNumber, which reads as a whole number when it has no fraction.
        #expect(forced(["MaxRuntimeMinutes": NSNumber(value: 0.0)]).maxRuntimeMinutes == nil)
        #expect(forced(["MaxRuntimeMinutes": NSNumber(value: 60.0)]).maxRuntimeMinutes == 60)
    }

    @Test func anyOtherForcedRuntimeOutsideTheEditorRangeBecomesFifteenMinutes() {
        let values: [Any] = [false, NSNumber(value: false), true, -5, 1, 1_441, "0"]
        for value in values {
            let policy = forced(["MaxRuntimeMinutes": value])
            #expect(policy.maxRuntimeMinutes == EditorLimits.runtimeStepMinutes, "\(value)")
            #expect(policy.isLocked(.maxRuntimeMinutes), "\(value)")
        }
    }

    @Test func aValueTheUserWroteIsNotPolicy() throws {
        let scratch = try ScratchDefaults()
        defer { scratch.cleanUp() }
        for key in ManagedKey.allCases { scratch.defaults.set(false, forKey: key.rawValue) }
        #expect(ManagedPreferences(reading: scratch.defaults) == ManagedPreferences(forcedValue: { _ in nil }))
    }

    @Test func aControlIsLockedOnlyWhereThePolicyRestricts() {
        let policy = forced(["AllowSharedFolders": false, "AllowMicrophone": true, "MaxRuntimeMinutes": 60])
        #expect(policy.isLocked(.allowSharedFolders))
        #expect(!policy.isLocked(.allowMicrophone), "an allowed feature is not locked")
        #expect(policy.isLocked(.maxRuntimeMinutes))
        #expect(!policy.isLocked(.requireDisposableMachines))
        let nothing = ManagedPreferences(forcedValue: { _ in nil })
        #expect(ManagedKey.allCases.allSatisfy { !nothing.isLocked($0) })
    }

    @Test func anAppSettingIsLockedOnlyWhenItsValueIsForced() {
        let policy = forced(["keepsRestoreImages": true, "AllowMicrophone": false])
        #expect(policy.isLocked(.keepsRestoreImages))
        #expect(!policy.isLocked(.hidesToolbarInFullScreen))
        #expect(AppSetting.allCases.allSatisfy { !ManagedPreferences(forcedValue: { _ in nil }).isLocked($0) })
    }

    @Test func aDeniedControlServiceLocksItAndTurnsAgentAccessOffOnEveryMachine() {
        var config = VMConfig.new(name: "m", guest: .linux)
        config.agentAccess = true
        let refusals: [Any] = [false, "yes", 0]
        for value in refusals {
            let policy = forced(["AllowControlService": value])
            #expect(policy.isLocked(.allowControlService), "\(value)")
            #expect(!policy.clamp(config).agentAccess, "\(value)")
        }
        let allowed = forced(["AllowControlService": true])
        #expect(!allowed.isLocked(.allowControlService))
        #expect(allowed.clamp(config).agentAccess)
        #expect(ManagedPreferences(forcedValue: { _ in nil }).clamp(config).agentAccess, "nothing forced changes nothing")
    }

    @Test func aDeniedProvisioningKeyRemovesTheSpecFromEveryMachineAndLocksTheChooser() {
        var config = VMConfig.new(name: "m", guest: .linux)
        config.provisioningSpecPath = "/Users/me/machine.yaml"
        let refusals: [Any] = [false, "yes", 0]
        for value in refusals {
            let policy = forced(["AllowProvisioning": value])
            #expect(policy.isLocked(.allowProvisioning), "\(value)")
            #expect(policy.clamp(config).provisioningSpecPath.isEmpty, "\(value)")
        }
        let allowed = forced(["AllowProvisioning": true])
        #expect(!allowed.isLocked(.allowProvisioning))
        #expect(allowed.clamp(config) == config)
        #expect(ManagedPreferences(forcedValue: { _ in nil }).clamp(config) == config, "nothing forced changes nothing")
    }

    @Test func theControlServiceSwitchIsLockedWhenItsValueIsForced() {
        #expect(forced(["runsControlService": false]).isLocked(.runsControlService))
        #expect(!forced([:]).isLocked(.runsControlService))
    }

    @Test func theHelpNamesEveryKeyThatCanBeManaged() {
        let entry = HelpTopic.managedSettings.entry
        let text = (entry.paragraphs + entry.advanced).joined(separator: " ")
        for key in ManagedKey.allCases.map(\.rawValue) + AppSetting.allCases.map(\.rawValue) {
            #expect(text.contains("`\(key)`"), "missing: \(key)")
        }
        #expect(HelpTopic.settings.entry.related.contains(.managedSettings))
    }
}

/// The library brings every configuration it adds, changes or loads within the policy.
@MainActor
struct ManagedLibraryTests {
    @Test func theLibraryAppliesThePolicyToWhatItAddsChangesAndLoads() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = ManagedPreferences(forcedValue: { $0 == ManagedKey.allowSharedFolders.rawValue ? false as Any : nil })
        let library = VMLibrary(machinesDirectory: directory, saveDelay: .seconds(3600), managed: policy)
        var config = VMConfig.new(name: "m", guest: .linux)
        config.sharedFolders = [SharedFolder(path: "/tmp/a")]
        try library.add(config)
        #expect(library.machine(config.id)?.sharedFolders.isEmpty == true)
        library.update(config)
        #expect(library.machine(config.id)?.sharedFolders.isEmpty == true)

        // A file written before the policy arrived is brought within it as it loads.
        try config.encoded().writePrivately(to: library.bundle(config.id).config)
        let reloaded = VMLibrary(machinesDirectory: directory, managed: policy)
        reloaded.load()
        #expect(reloaded.machine(config.id)?.sharedFolders.isEmpty == true)
    }
}
