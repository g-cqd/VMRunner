import Foundation
import Testing
import Virtualization

@testable import PrivateInterfaces

/// A runtime failure takes precedence over a selector probe: matching encodings do not establish safe guest execution.
struct PMUSafetyTests {
    private struct NoLookup: MethodResolver {
        func lookup(className: String, selector: String) -> MethodLookup {
            Issue.record("an unsafe build must be refused before looking up \(className).\(selector)")
            return .classMissing
        }
    }

    @Test(arguments: ["26A434", "26A434a"])
    func theBuildWhoseHelperCrashedIsRefusedBeforeLookup(build: String) {
        let context = PrivateCapabilityContext(osBuild: build, killed: [], resolver: NoLookup())
        let status = PMUEmulation.status(in: context)
        guard case .unavailable(let reason) = status else {
            Issue.record("the known-crashing host build was allowed")
            return
        }
        #expect(reason.description == "macOS build \(build) is disabled because this capability crashed the virtualization helper")
    }

    @Test
    func applyingOnTheUnsafeBuildDoesNotReachTheSetter() {
        let context = PrivateCapabilityContext(osBuild: "26A434", killed: [], resolver: NoLookup())
        let configuration = VZGenericPlatformConfiguration()
        let status = PMUEmulation.apply(to: configuration, in: context)
        guard case .unavailable(let reason) = status else {
            Issue.record("the known-crashing capability was applied")
            return
        }
        #expect(reason.description == "macOS build 26A434 is disabled because this capability crashed the virtualization helper")
    }

    @Test
    func theRefusalIsSpecificToTheRecordedBuild() {
        struct Matching: MethodResolver {
            func lookup(className: String, selector: String) -> MethodLookup {
                .found(encoding: selector.hasSuffix(":") ? "v20@0:8B16" : "B16@0:8")
            }
        }
        for build in ["26A433", "26A435"] {
            let context = PrivateCapabilityContext(osBuild: build, killed: [], resolver: Matching())
            #expect(PMUEmulation.status(in: context) == .available, "selector compatibility, not a guest-boot claim")
        }
    }

    @Test
    func theKillSwitchStillWinsOverTheRuntimeFailure() {
        let context = PrivateCapabilityContext(
            osBuild: "26A434", killed: [.performanceMonitoringEmulation], resolver: NoLookup())
        #expect(PMUEmulation.status(in: context) == .unavailable(.killSwitch))
    }
}
