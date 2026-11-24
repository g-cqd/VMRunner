import Foundation

/// One method the capability calls: the class, the selector, and the type encoding with its digits removed (`v@:B` for a
/// setter of a boolean), because the digits are offsets that change with the architecture and the SDK.
package struct MethodContract: Equatable, Sendable {
    package let className: String
    package let selector: String
    package let encoding: String

    package init(className: String, selector: String, encoding: String) {
        self.className = className
        self.selector = selector
        self.encoding = encoding
    }
}

/// What the runtime says about one instance method.
package enum MethodLookup: Equatable, Sendable {
    case classMissing
    case methodMissing
    case found(encoding: String)
}

/// Finds an instance method by class and selector name. The real one asks the Objective-C runtime; tests use a fake.
package protocol MethodResolver: Sendable {
    func lookup(className: String, selector: String) -> MethodLookup
}

/// The Objective-C runtime, asked by name. Nothing is called and no instance is made.
package struct RuntimeMethodResolver: MethodResolver {
    package init() {}

    package func lookup(className: String, selector: String) -> MethodLookup {
        guard let candidate = NSClassFromString(className) else { return .classMissing }
        guard let method = unsafe class_getInstanceMethod(candidate, NSSelectorFromString(selector)),
            let raw = unsafe method_getTypeEncoding(method)
        else { return .methodMissing }
        return .found(encoding: unsafe String(cString: raw))
    }
}

/// Everything a capability's check depends on, so a test can state it.
package struct PrivateCapabilityContext: Sendable {
    /// `kern.osversion`, or `nil` when it could not be read.
    package var osBuild: String?
    /// The capabilities turned off by the kill switch, by the user's settings or by an organisation.
    package var killed: Set<PrivateCapabilityID>
    package var resolver: any MethodResolver

    package init(osBuild: String?, killed: Set<PrivateCapabilityID>, resolver: any MethodResolver) {
        self.osBuild = osBuild
        self.killed = killed
        self.resolver = resolver
    }

    /// This Mac, with the given capabilities turned off.
    package static func current(killed: Set<PrivateCapabilityID> = []) -> Self {
        Self(osBuild: OSBuild.running, killed: killed, resolver: RuntimeMethodResolver())
    }
}

/// A capability that is a boolean switch on an object of the framework: a setter, a getter that reads the value back, and the
/// builds of macOS the pair was verified on.
package struct CapabilityEntry: Sendable {
    package let id: PrivateCapabilityID
    package let builds: ClosedRange<OSBuild>
    /// Runtime failures override a successful selector probe on these builds.
    package let unsafeBuilds: [OSBuild]
    package let setter: MethodContract
    package let getter: MethodContract

    package init(
        id: PrivateCapabilityID, builds: ClosedRange<OSBuild>, unsafeBuilds: [OSBuild] = [],
        setter: MethodContract, getter: MethodContract
    ) {
        self.id = id
        self.builds = builds
        self.unsafeBuilds = unsafeBuilds
        self.setter = setter
        self.getter = getter
    }

    /// Whether the capability can be used, without touching any object: the kill switch, the build of macOS, then each method
    /// by class, selector and type encoding. The first failure is the answer; nothing is called.
    package func status(in context: PrivateCapabilityContext) -> PrivateCapabilityStatus {
        if context.killed.contains(id) { return .unavailable(.killSwitch) }
        guard let text = context.osBuild, let build = OSBuild(text) else { return .unavailable(.osBuildUnreadable) }
        guard builds.contains(build) else {
            return .unavailable(.osBuildOutsideRange(build: text, verified: "\(builds.lowerBound) to \(builds.upperBound)"))
        }
        guard !unsafeBuilds.contains(build) else { return .unavailable(.unsafeHostBuild(text)) }
        for method in [setter, getter] {
            switch context.resolver.lookup(className: method.className, selector: method.selector) {
            case .classMissing:
                return .unavailable(.classMissing(method.className))
            case .methodMissing:
                return .unavailable(.selectorMissing(class: method.className, selector: method.selector))
            case .found(let encoding):
                let stripped = String(encoding.filter { !$0.isNumber })
                if stripped != method.encoding {
                    return .unavailable(.encodingMismatch(selector: method.selector, expected: method.encoding, found: stripped))
                }
            }
        }
        return .available
    }
}

/// The capabilities the app knows, by id. A test builds its own to state a case the real one cannot be put in.
package struct CapabilityRegistry: Sendable {
    package var entries: [PrivateCapabilityID: CapabilityEntry]

    package init(entries: [CapabilityEntry]) {
        self.entries = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Generic-platform Boolean capabilities; the framebuffer boot pair has its own narrower execution scope (ADR-0060).
    package static let standard = Self(entries: [PMUEmulation.entry, WindowsBootEmulation.traps])
}
