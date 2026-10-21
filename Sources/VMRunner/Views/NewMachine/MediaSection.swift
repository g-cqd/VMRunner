import SwiftUI
import UniformTypeIdentifiers

/// Where the installation media comes from: a macOS restore image or a Linux ISO.
struct MediaSection: View {
    @Bindable var model: NewMachineModel

    @State private var importing = false

    private var ipswType: UTType { UTType(filenameExtension: "ipsw") ?? .data }

    var body: some View {
        Section {
            if model.config.guest == .macOS { macControls } else { linuxControls }
        } header: {
            HelpHeader(
                model.config.guest == .macOS ? "Restore image" : "Installation media",
                topic: model.config.guest == .macOS ? .macRestoreImage : .linuxImages)
        }
        .fileImporter(
            isPresented: $importing, allowedContentTypes: model.config.guest == .macOS ? [ipswType] : [.diskImage, .data]
        ) { result in
            if let url = try? result.get() { model.localPath = url.path }
        }
    }

    // MARK: macOS

    @ViewBuilder
    private var macControls: some View {
        Picker("Source", selection: $model.macSource) {
            ForEach(NewMachineModel.MacSource.allCases) { Text($0.rawValue).tag($0) }
        }
        switch model.macSource {
        case .latest:
            Text("The newest macOS this Mac can virtualize, straight from Apple.")
                .font(.caption).foregroundStyle(.secondary)
        case .ipswMe:
            ipswMeControls
        case .file:
            fileRow(placeholder: "Choose .ipsw…")
        }
    }

    @ViewBuilder
    private var ipswMeControls: some View {
        HStack {
            TextField("Mac model", text: $model.deviceIdentifier, prompt: Text("e.g. Mac14,15"))
            Button("Load") { Task { await model.loadFirmwares() } }
                .disabled(model.deviceIdentifier.isEmpty || model.isLoadingFirmwares)
        }
        if model.isLoadingFirmwares { ProgressView().controlSize(.small) }
        if let error = model.loadError { Text(error).foregroundStyle(.red) }
        if !model.firmwares.isEmpty {
            Picker("Version", selection: $model.selectedBuild) {
                Text("Choose…").tag(String?.none)
                ForEach(model.firmwares) { Text($0.label).tag(String?.some($0.buildid)) }
            }
        }
        Text(
            "Signed restore images from ipsw.me. They're universal, so any Apple silicon model lists the same builds. "
                + "A single download is ~20–27 GB."
        )
        .font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Linux

    @ViewBuilder
    private var linuxControls: some View {
        Picker("Image", selection: $model.linuxSource) {
            ForEach(LinuxCatalog.images) { Text($0.title).tag(NewMachineModel.LinuxSource.catalog($0.id)) }
            Text("Local ISO…").tag(NewMachineModel.LinuxSource.file)
        }
        if case .file = model.linuxSource {
            fileRow(placeholder: "Choose ISO…")
        } else {
            Text("Apple silicon runs arm64 guests only. The newest ISO and its SHA-256 are looked up on the project's own server.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func fileRow(placeholder: String) -> some View {
        HStack {
            Text(model.localPath.map { URL(filePath: $0).lastPathComponent } ?? "None selected")
                .foregroundStyle(model.localPath == nil ? .secondary : .primary)
            Spacer()
            Button(placeholder) { importing = true }
        }
    }
}
