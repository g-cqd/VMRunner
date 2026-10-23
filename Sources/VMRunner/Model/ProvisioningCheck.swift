import Foundation
import GuestSeed

/// What the editor shows about a provisioning spec: one line per step the next start would pack, or why it would refuse.
/// A preview only: the start reads the spec and its scripts again and decides (`ProvisioningSeed.prepare`).
enum ProvisioningCheck: Equatable, Sendable {
    case ready([String])
    case refused(String)

    init(specAt path: String) {
        do {
            let spec = try ProvisioningSeed.compile(specAt: path, instanceID: "check").spec
            let steps = spec.steps.map { Self.line(for: $0) }
            self = .ready(spec.cloudInit.userData == nil ? steps : steps + ["Your own cloud-init data, merged with the steps"])
        } catch let error as ProvisioningSeedError {
            self = .refused(error.reason)
        } catch {
            self = .refused(error.localizedDescription)
        }
    }

    /// "line 7: first-boot, inline script", or "line 11: every-boot, scripts/hello.sh, sha256 9fac65956eed…".
    static func line(for step: ProvisioningStep) -> String {
        switch step.script {
        case .inline: "line \(step.line): \(step.phase.rawValue), inline script"
        case .file(let path, let sha256): "line \(step.line): \(step.phase.rawValue), \(path), sha256 \(sha256.prefix(12))…"
        }
    }
}
