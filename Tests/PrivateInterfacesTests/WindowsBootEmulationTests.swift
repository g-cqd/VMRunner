import Foundation
import Testing

@testable import PrivateInterfaces

@objc(WindowsBootTestSwitches)
private final class BootSwitches: NSObject {
    var monitoring = false
    var traps = false
    var refuseTraps = false
    var monitoringCalls: [Bool] = []
    var trapCalls: [Bool] = []
    @objc func setMonitoring(_ value: Bool) {
        monitoringCalls.append(value)
        monitoring = value
    }
    @objc func getMonitoring() -> Bool { monitoring }
    @objc func setTraps(_ value: Bool) {
        trapCalls.append(value)
        if !refuseTraps { traps = value }
    }
    @objc func getTraps() -> Bool { traps }
}

struct WindowsBootEmulationTests {
    private let context = PrivateCapabilityContext(osBuild: "26A434", killed: [], resolver: RuntimeMethodResolver())
    private func entry(_ id: PrivateCapabilityID, _ setter: String, _ getter: String) -> CapabilityEntry {
        CapabilityEntry(
            id: id, builds: WindowsBootEmulation.traps.builds,
            setter: MethodContract(className: "WindowsBootTestSwitches", selector: setter, encoding: "v@:B"),
            getter: MethodContract(className: "WindowsBootTestSwitches", selector: getter, encoding: "B@:"))
    }
    private var monitoring: CapabilityEntry { entry(.performanceMonitoringEmulation, "setMonitoring:", "getMonitoring") }
    private var traps: CapabilityEntry { entry(.fineGrainedTrapsEmulation, "setTraps:", "getTraps") }

    @Test func bothSwitchesAreEnabledAndReadBack() {
        let object = BootSwitches()
        #expect(WindowsBootEmulation.applyPair(to: object, in: context, first: monitoring, second: traps) == .available)
        #expect(object.monitoring && object.traps)
        #expect(object.monitoringCalls == [true] && object.trapCalls == [true])
    }

    @Test func aMissingSecondContractCallsNeitherSetter() {
        let object = BootSwitches()
        let missing = entry(.fineGrainedTrapsEmulation, "missing:", "getTraps")
        #expect(!WindowsBootEmulation.applyPair(to: object, in: context, first: monitoring, second: missing).isAvailable)
        #expect(object.monitoringCalls.isEmpty && object.trapCalls.isEmpty)
    }

    @Test(arguments: [false, true]) func secondReadBackFailureRestoresTheFirstOriginalValue(original: Bool) {
        let object = BootSwitches()
        object.monitoring = original
        object.refuseTraps = true
        let status = WindowsBootEmulation.applyPair(to: object, in: context, first: monitoring, second: traps)
        #expect(status == .unavailable(.readBackMismatch(selector: "setTraps:")))
        #expect(object.monitoring == original && !object.traps)
        #expect(object.monitoringCalls == [true, original])
        #expect(object.trapCalls == [true, false])
    }

    @Test(arguments: [PrivateCapabilityID.performanceMonitoringEmulation, .fineGrainedTrapsEmulation])
    func eitherKillSwitchPreventsBothSetters(id: PrivateCapabilityID) {
        let object = BootSwitches()
        var killed = context
        killed.killed = [id]
        #expect(WindowsBootEmulation.applyPair(to: object, in: killed, first: monitoring, second: traps) == .unavailable(.killSwitch))
        #expect(object.monitoringCalls.isEmpty && object.trapCalls.isEmpty)
    }

    @Test(arguments: ["26A433", "26A435", "26B1", "27A1", "invalid"])
    func onlyTheObservedBuildIsAllowed(build: String) {
        var outside = context
        outside.osBuild = build
        let object = BootSwitches()
        #expect(!WindowsBootEmulation.applyPair(to: object, in: outside, first: monitoring, second: traps).isAvailable)
        #expect(object.monitoringCalls.isEmpty && object.trapCalls.isEmpty)
    }

    @Test func standaloneMonitoringRemainsBlockedOnTheObservedBuild() {
        #expect(PMUEmulation.entry.status(in: context) == .unavailable(.unsafeHostBuild("26A434")))
    }
}
