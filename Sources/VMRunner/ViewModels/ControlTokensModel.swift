import ControlProtocol
import Foundation
import Observation

/// The token list in Settings (ADR-0056): make a token and show its secret once, list the tokens, revoke one.
@MainActor @Observable
final class ControlTokensModel {
    private(set) var tokens: [ControlToken] = []
    /// The secret of the token just made, shown until the user dismisses it; then it is gone, only its digest is stored.
    var newSecret: String?
    var errorMessage: String?
    var draftName = ""
    var draftCapabilities: Set<ControlCapability> = [.list, .state]
    @ObservationIgnored private let store: @MainActor () throws -> ControlTokenStore

    /// `store` is the service's token store; a test gives one in a scratch folder.
    init(store: @escaping @MainActor () throws -> ControlTokenStore = { try ControlService.shared.tokenStore() }) {
        self.store = store
    }

    func refresh() {
        do {
            tokens = try store().all.sorted { $0.created < $1.created }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func create() {
        do {
            let made = try store().create(name: draftName, capabilities: draftCapabilities)
            newSecret = made.secret
            draftName = ""
            errorMessage = nil
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revoke(_ id: UUID) {
        do {
            try store().revoke(id)
            errorMessage = nil
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setCapability(_ capability: ControlCapability, _ isOn: Bool) {
        if isOn { draftCapabilities.insert(capability) } else { draftCapabilities.remove(capability) }
    }

    /// What a token allows, in a fixed order, for its row.
    static func summary(of token: ControlToken) -> String {
        ControlCapability.allCases.filter(token.capabilities.contains).map(\.label).joined(separator: ", ")
    }
}
