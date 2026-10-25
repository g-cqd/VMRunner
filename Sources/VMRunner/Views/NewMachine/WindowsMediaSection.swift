import SwiftUI
import UniformTypeIdentifiers

/// A Windows machine's installation media: an installer ISO from this Mac with an optional expected SHA-256, and an optional
/// driver disc. Both are local files chosen in the open panel; the app offers no download and no address field.
struct WindowsMediaSection: View {
    @Bindable var model: NewMachineModel

    @State private var target: Slot?

    private enum Slot: Identifiable {
        case installer, driverDisc
        var id: Self { self }
    }

    var body: some View {
        Section {
            fileRow("Installer ISO", path: model.localPath) { target = .installer }
            note(WindowsRequirements.installerNote)
            TextField("Expected SHA-256", text: $model.expectedSHA256, prompt: Text("Optional: 64 hexadecimal digits"))
                .font(.body.monospaced())
                .disabled(model.isVerifying)
            if let problem = InstallerDigest.problem(in: model.expectedSHA256) {
                Label(problem.localizedDescription, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            note(WindowsRequirements.expectedSHA256Note)
            fileRow("Driver disc (optional)", path: model.driverDiscPath) { target = .driverDisc }
            if model.driverDiscPath != nil {
                Button("Remove Driver Disc", role: .destructive) { model.driverDiscPath = nil }
                    .disabled(model.isVerifying)
            }
            note(WindowsRequirements.driverDiscNote)
            if model.isVerifying {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking the installer…")
                }
            }
        } header: {
            HelpHeader("Windows installation media", topic: .windowsMachines)
        }
        .fileImporter(
            isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }), allowedContentTypes: [.diskImage, .data]
        ) { [slot = target] result in
            guard let url = try? result.get() else { return }
            if slot == .driverDisc { model.chooseDriverDisc(url) } else { model.chooseLocalFile(url) }
        }
    }

    private func fileRow(_ title: String, path: String?, choose: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                Text(path.map { URL(filePath: $0).lastPathComponent } ?? "None selected")
                    .foregroundStyle(path == nil ? .secondary : .primary)
                Button(path == nil ? "Choose ISO…" : "Change ISO…", action: choose)
                    .disabled(model.isVerifying)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

/// What a person should know before they make a Windows machine, one statement per line (`WindowsRequirements`).
struct WindowsRequirementsSection: View {
    var body: some View {
        Section {
            ForEach(WindowsRequirements.lines, id: \.self) { line in
                Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Requirements")
        }
    }
}
