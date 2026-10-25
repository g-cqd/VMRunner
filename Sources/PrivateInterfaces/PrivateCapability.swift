/// A behaviour the app reaches only through an interface the framework does not document.
package enum PrivateCapabilityID: String, CaseIterable, Sendable {
    case performanceMonitoringEmulation

    /// What the exposure summary, the help and a start error call it.
    package var title: String {
        switch self {
        case .performanceMonitoringEmulation: "performance-monitoring emulation"
        }
    }
}

/// Whether a capability can be used right now, and if not, the first check that failed.
package enum PrivateCapabilityStatus: Equatable, Sendable {
    case available
    case unavailable(PrivateCapabilityReason)

    package var isAvailable: Bool { self == .available }
}

/// Why a capability is off. The text names the cause in words a start error can show.
package enum PrivateCapabilityReason: Equatable, Sendable, CustomStringConvertible {
    case killSwitch
    case notRegistered
    case osBuildUnreadable
    case osBuildOutsideRange(build: String, verified: String)
    case classMissing(String)
    case receiverMismatch(class: String)
    case selectorMissing(class: String, selector: String)
    case encodingMismatch(selector: String, expected: String, found: String)
    case readBackMismatch(selector: String)

    package var description: String {
        switch self {
        case .killSwitch:
            "its kill switch is on"
        case .notRegistered:
            "this app does not register it"
        case .osBuildUnreadable:
            "the build of macOS could not be read"
        case .osBuildOutsideRange(let build, let verified):
            "macOS build \(build) is outside the builds it was verified on (\(verified))"
        case .classMissing(let name):
            "this macOS has no class \(name)"
        case .receiverMismatch(let name):
            "the object is not a \(name)"
        case .selectorMissing(let name, let selector):
            "this macOS has no method \(selector) on \(name)"
        case .encodingMismatch(let selector, let expected, let found):
            "the method \(selector) has type \(found), not the expected \(expected)"
        case .readBackMismatch(let selector):
            "the value set through \(selector) was not kept"
        }
    }
}
