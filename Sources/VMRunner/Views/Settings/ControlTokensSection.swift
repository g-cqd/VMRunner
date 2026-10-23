import AppKit
import ControlProtocol
import SwiftUI

/// Settings' list of control tokens: make one (its secret is shown once), see what each allows, revoke one.
struct ControlTokensSection: View {
    @State private var model = ControlTokensModel()

    var body: some View {
        Section {
            ForEach(model.tokens) { token in
                LabeledContent {
                    Button("Revoke", role: .destructive) { model.revoke(token.id) }
                } label: {
                    Text(token.name)
                    Text(ControlTokensModel.summary(of: token))
                }
            }
            if let secret = model.newSecret {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Copy this token now. VMRunner keeps only its fingerprint and cannot show it again.")
                        .font(.caption)
                    Text(secret).font(.body.monospaced()).textSelection(.enabled)
                    HStack {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(secret, forType: .string)
                            // Clipboard managers and the clipboard of other devices skip what is marked as concealed or remote.
                            for marker in ["org.nspasteboard.ConcealedType", "com.apple.is-remote-clipboard"] {
                                NSPasteboard.general.setData(Data(), forType: NSPasteboard.PasteboardType(rawValue: marker))
                            }
                        }
                        Button("Done") { model.newSecret = nil }
                    }
                }
            }
            TextField("Name of a new token", text: $model.draftName)
            ForEach(ControlCapability.allCases, id: \.self) { capability in
                Toggle(
                    capability.label,
                    isOn: Binding(
                        get: { model.draftCapabilities.contains(capability) }, set: { model.setCapability(capability, $0) }))
            }
            Button("Create Token", action: model.create)
                .disabled(model.draftName.trimmingCharacters(in: .whitespaces).isEmpty || model.draftCapabilities.isEmpty)
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            HelpHeader("Control tokens", topic: .controlTokens)
        }
        .task { model.refresh() }
    }
}
