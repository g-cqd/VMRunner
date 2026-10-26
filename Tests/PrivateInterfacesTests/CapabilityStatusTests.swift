import Testing

@testable import PrivateInterfaces

/// The fail-closed checks of a capability, with a resolver that answers from a table: none of these needs the framework's real
/// selectors, so they run on every macOS.
struct CapabilityStatusTests {
    private static let setter = MethodContract(className: "FakeHost", selector: "_setFlag:", encoding: "v@:B")
    private static let getter = MethodContract(className: "FakeHost", selector: "_flag", encoding: "B@:")
    private static let entry = CapabilityEntry(
        id: .performanceMonitoringEmulation,
        builds: PMUEmulation.entry.builds,
        setter: setter, getter: getter)

    private struct FakeResolver: MethodResolver {
        var answers: [String: MethodLookup]

        func lookup(className: String, selector: String) -> MethodLookup {
            answers["\(className).\(selector)"] ?? (answers[className] == nil ? .classMissing : .methodMissing)
        }

        /// A class that has both methods with the encodings the framework reports (offsets included).
        static let matching = Self(answers: [
            "FakeHost": .methodMissing,
            "FakeHost._setFlag:": .found(encoding: "v20@0:8B16"),
            "FakeHost._flag": .found(encoding: "B16@0:8"),
        ])

        func replacing(_ key: String, with lookup: MethodLookup?) -> Self {
            var copy = self
            copy.answers[key] = lookup
            return copy
        }
    }

    private func context(
        build: String? = "26A434", killed: Set<PrivateCapabilityID> = [], resolver: FakeResolver = .matching
    ) -> PrivateCapabilityContext {
        PrivateCapabilityContext(osBuild: build, killed: killed, resolver: resolver)
    }

    @Test
    func aMatchingPairOnAVerifiedBuildIsAvailable() {
        #expect(Self.entry.status(in: context()) == .available)
        #expect(Self.entry.status(in: context(build: "26A5289g")) == .available)
    }

    @Test
    func theKillSwitchTurnsItOffBeforeAnythingIsLookedUp() {
        let status = Self.entry.status(in: context(killed: [.performanceMonitoringEmulation], resolver: FakeResolver(answers: [:])))
        #expect(status == .unavailable(.killSwitch))
        #expect(PrivateCapabilityStatus.unavailable(.killSwitch).isAvailable == false)
    }

    @Test(arguments: ["25H100", "27A1", "26"])
    func aBuildOutsideTheVerifiedRangeOrNotABuildIsOff(build: String) {
        let status = Self.entry.status(in: context(build: build))
        #expect(status != .available)
        if OSBuild(build) == nil {
            #expect(status == .unavailable(.osBuildUnreadable))
        } else {
            #expect(status == .unavailable(.osBuildOutsideRange(build: build, verified: "26A0 to 26Z99999")))
        }
    }

    @Test
    func aBuildThatCouldNotBeReadIsOff() {
        #expect(Self.entry.status(in: context(build: nil)) == .unavailable(.osBuildUnreadable))
    }

    @Test
    func aMissingClassAMissingSelectorAndAWrongEncodingAreEachOffWithTheirOwnReason() {
        let noClass = FakeResolver(answers: [:])
        #expect(Self.entry.status(in: context(resolver: noClass)) == .unavailable(.classMissing("FakeHost")))
        let noSetter = FakeResolver.matching.replacing("FakeHost._setFlag:", with: nil)
        #expect(
            Self.entry.status(in: context(resolver: noSetter))
                == .unavailable(.selectorMissing(class: "FakeHost", selector: "_setFlag:")))
        let noGetter = FakeResolver.matching.replacing("FakeHost._flag", with: nil)
        #expect(
            Self.entry.status(in: context(resolver: noGetter)) == .unavailable(.selectorMissing(class: "FakeHost", selector: "_flag")))
        let wideSetter = FakeResolver.matching.replacing("FakeHost._setFlag:", with: .found(encoding: "v24@0:8q16"))
        #expect(
            Self.entry.status(in: context(resolver: wideSetter))
                == .unavailable(.encodingMismatch(selector: "_setFlag:", expected: "v@:B", found: "v@:q")))
        let getterReturningVoid = FakeResolver.matching.replacing("FakeHost._flag", with: .found(encoding: "v16@0:8"))
        #expect(Self.entry.status(in: context(resolver: getterReturningVoid)) != .available)
    }

    @Test
    func everyReasonSaysInWordsWhatIsWrong() {
        let reasons: [PrivateCapabilityReason] = [
            .killSwitch, .notRegistered, .osBuildUnreadable, .osBuildOutsideRange(build: "25H100", verified: "26A0 to 26Z99999"),
            .unsafeHostBuild("26A434"), .classMissing("C"), .receiverMismatch(class: "C"),
            .selectorMissing(class: "C", selector: "_s:"),
            .encodingMismatch(selector: "_s:", expected: "v@:B", found: "v@:q"), .readBackMismatch(selector: "_s:"),
        ]
        #expect(Set(reasons.map(\.description)).count == reasons.count, "no two reasons read alike")
        #expect(reasons.allSatisfy { !$0.description.isEmpty })
        #expect(PrivateCapabilityID.performanceMonitoringEmulation.title == "performance-monitoring emulation")
    }

    @Test
    func aRegistryThatLacksTheCapabilityReportsItUnregistered() {
        let empty = CapabilityRegistry(entries: [])
        #expect(PMUEmulation.status(in: context(), registry: empty) == .unavailable(.notRegistered))
        let registry = CapabilityRegistry(entries: [Self.entry, Self.entry])
        #expect(registry.entries.count == 1, "a repeated id keeps its first entry")
    }
}
