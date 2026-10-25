import Foundation
import Testing

@testable import PrivateInterfaces

/// Objects that answer to the same selectors the framework's configuration does, so the call, the read-back and the
/// restoring can be tested without the framework's private ones.
@objc(PrivateInterfacesTestSwitch)
private class TestSwitch: NSObject {
    var flag = false
    @objc(_setFlag:) func setFlag(_ value: Bool) { flag = value }
    @objc(_flag) func readFlag() -> Bool { flag }
}

/// Ignores what it is told, as a setter that no longer does what it did would.
@objc(PrivateInterfacesTestStuckSwitch)
private final class StuckSwitch: NSObject {
    var calls: [Bool] = []
    @objc(_setFlag:) func setFlag(_ value: Bool) { calls.append(value) }
    @objc(_flag) func readFlag() -> Bool { false }
}

/// How often a method added to a subclass at run time was called.
private final class CallCounter {
    var calls = 0
}

struct CapabilityApplyTests {
    private static func entry(_ className: String) -> CapabilityEntry {
        CapabilityEntry(
            id: .performanceMonitoringEmulation,
            builds: PMUEmulation.entry.builds,
            setter: MethodContract(className: className, selector: "_setFlag:", encoding: "v@:B"),
            getter: MethodContract(className: className, selector: "_flag", encoding: "B@:"))
    }

    private let context = PrivateCapabilityContext(osBuild: "26A434", killed: [], resolver: RuntimeMethodResolver())

    @Test
    func theRuntimeResolverReadsTheEncodingsOfARealClass() {
        let resolver = RuntimeMethodResolver()
        #expect(resolver.lookup(className: "PrivateInterfacesTestSwitch", selector: "_setFlag:") == .found(encoding: "v20@0:8B16"))
        #expect(resolver.lookup(className: "PrivateInterfacesTestSwitch", selector: "_flag") == .found(encoding: "B16@0:8"))
        #expect(resolver.lookup(className: "PrivateInterfacesTestSwitch", selector: "_nothing") == .methodMissing)
        #expect(resolver.lookup(className: "PrivateInterfacesNoSuchClass", selector: "_flag") == .classMissing)
    }

    @Test
    func theValueIsSetAndReadBack() {
        let object = TestSwitch()
        #expect(Self.entry("PrivateInterfacesTestSwitch").apply(true, to: object, in: context) == .available)
        #expect(object.flag)
        #expect(Self.entry("PrivateInterfacesTestSwitch").apply(false, to: object, in: context) == .available)
        #expect(!object.flag)
    }

    @Test
    func aValueThatIsNotKeptIsReportedAndTheOldValueIsPutBack() {
        let object = StuckSwitch()
        let status = Self.entry("PrivateInterfacesTestStuckSwitch").apply(true, to: object, in: context)
        #expect(status == .unavailable(.readBackMismatch(selector: "_setFlag:")))
        #expect(object.calls == [true, false], "set, then the value the switch had before")
    }

    @Test
    func theKillSwitchAndAWrongReceiverCallNothing() {
        let object = StuckSwitch()
        let killed = PrivateCapabilityContext(
            osBuild: "26A434", killed: [.performanceMonitoringEmulation], resolver: RuntimeMethodResolver())
        #expect(Self.entry("PrivateInterfacesTestStuckSwitch").apply(true, to: object, in: killed) == .unavailable(.killSwitch))
        let wrong = Self.entry("PrivateInterfacesTestStuckSwitch").apply(true, to: TestSwitch(), in: context)
        #expect(wrong == .unavailable(.receiverMismatch(class: "PrivateInterfacesTestStuckSwitch")))
        let outside = PrivateCapabilityContext(osBuild: "25H100", killed: [], resolver: RuntimeMethodResolver())
        #expect(Self.entry("PrivateInterfacesTestStuckSwitch").apply(true, to: object, in: outside) != .available)
        #expect(object.calls.isEmpty)
    }

    @Test
    func aClassTheRuntimeLacksIsUnavailableAndCallsNothing() {
        let status = Self.entry("PrivateInterfacesNoSuchClass").apply(true, to: TestSwitch(), in: context)
        #expect(status == .unavailable(.classMissing("PrivateInterfacesNoSuchClass")))
    }

    @Test
    func aSubclassThatGivesTheSetterAnotherTypeIsRefusedAndItsMethodIsNotCalled() throws {
        let counter = CallCounter()
        let name = "PrivateInterfacesTestRetypedSwitch"
        let retyped: AnyClass = try #require(unsafe objc_allocateClassPair(TestSwitch.self, name, 0))
        let body: @convention(block) (AnyObject, Int) -> Void = { _, _ in counter.calls += 1 }
        let added = unsafe class_addMethod(
            retyped, NSSelectorFromString("_setFlag:"), imp_implementationWithBlock(body), "v@:q")
        #expect(added)
        objc_registerClassPair(retyped)
        let object = try #require((retyped as? NSObject.Type)?.init() as? TestSwitch)

        let status = Self.entry("PrivateInterfacesTestSwitch").apply(true, to: object, in: context)

        #expect(status == .unavailable(.encodingMismatch(selector: "_setFlag:", expected: "v@:B", found: "v@:q")))
        #expect(counter.calls == 0 && !object.flag)
    }
}
