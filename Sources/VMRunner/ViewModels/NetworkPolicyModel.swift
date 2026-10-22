import Foundation
import NetPolicy
import Observation

/// State and actions behind the rule lists of the network policy editor. The simple fields (mode, private ranges, deny
/// action) are bound straight to the config; the lists need parsing, validation and limits, which live here.
@MainActor @Observable
final class NetworkPolicyModel {
    let id: UUID
    /// What has been typed into each list's "add" field and not added yet.
    var drafts: [PolicyList: String] = [:]

    // Unowned: the library owns the machine models, so a strong reference back would be a retain cycle.
    private unowned let library: VMLibrary

    init(id: UUID, library: VMLibrary) {
        self.id = id
        self.library = library
    }

    var policy: NetworkPolicy { library.machine(id)?.networkPolicy ?? NetworkPolicy() }

    /// Shown in allow-list mode when no destination is allowed, because the guest then has no network at all.
    var allowListWarning: String? {
        let current = policy
        guard current.mode == .allowListed, current.allowedDomains.isEmpty, current.allowedAddresses.isEmpty,
            current.allowedConnections.isEmpty
        else { return nil }
        return "Nothing is allowed yet, so the guest can't reach anything. Add a domain, address, or connection."
    }

    func rules(in list: PolicyList) -> [String] { policy.rules(in: list) }

    func count(in list: PolicyList) -> Int { rules(in: list).count }

    /// Why the text typed for `list` can't be added, in the engine's own words; `nil` while the field is empty or valid.
    func problem(for list: PolicyList) -> String? {
        let text = draft(for: list)
        if text.isBlank { return nil }
        if isFull(list) { return "A list holds at most \(EditorLimits.maxRulesPerList) rules." }
        return NetworkPolicy.problem(with: text, for: list)?.localizedDescription
    }

    func canAdd(to list: PolicyList) -> Bool {
        !draft(for: list).isBlank && !isFull(list) && NetworkPolicy.problem(with: draft(for: list), for: list) == nil
    }

    /// Adds the typed rule and clears the field. A rule that doesn't parse leaves both untouched (the field shows why).
    func add(to list: PolicyList) {
        guard canAdd(to: list), var config = library.machine(id) else { return }
        do {
            try config.networkPolicy.add(draft(for: list), to: list)
        } catch {
            return
        }
        drafts[list] = ""
        library.update(config)
    }

    func remove(at index: Int, from list: PolicyList) {
        guard var config = library.machine(id) else { return }
        config.networkPolicy.remove(at: index, from: list)
        library.update(config)
    }

    private func draft(for list: PolicyList) -> String { drafts[list] ?? "" }

    private func isFull(_ list: PolicyList) -> Bool { count(in: list) >= EditorLimits.maxRulesPerList }
}

extension String {
    fileprivate var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

extension NetworkPolicy.Mode {
    var label: String {
        switch self {
        case .denyListed: "Block list"
        case .allowListed: "Allow list"
        }
    }

    var summary: String {
        switch self {
        case .denyListed: "Everything is allowed except what the block rules name."
        case .allowListed: "Everything is blocked except what the allow rules name. Block rules still win."
        }
    }
}
