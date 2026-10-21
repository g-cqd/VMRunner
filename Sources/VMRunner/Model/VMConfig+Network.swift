import Foundation

extension DenyAction {
    var label: String {
        switch self {
        case .reset: "Refuse the connection"
        case .drop: "Ignore it (the guest waits and times out)"
        }
    }
}

extension VMConfig {
    /// The user-mode stack's settings for this machine: everything else keeps the stack's defaults.
    var userNetConfig: UserNetConfig {
        var stack = UserNetConfig()
        stack.denyAction = networkDenyAction
        return stack
    }

    /// What the stack does with open connections when the Mac's network path changes.
    var hostPathChangeAction: ExistingFlowAction {
        networkResetsOnHostChange ? .terminate : .keep
    }
}

extension NetworkPolicy {
    /// Whether any rule is written as a DNS name. Name rules are advisory (see the help topic), so the exposure summary
    /// says so whenever they are in use.
    var usesDomainRules: Bool {
        let targetsName: (ConnectionRule) -> Bool = { rule in
            if case .name = rule.target { true } else { false }
        }
        return !allowedDomains.isEmpty || !blockedDomains.isEmpty
            || allowedConnections.contains(where: targetsName) || blockedConnections.contains(where: targetsName)
    }
}
