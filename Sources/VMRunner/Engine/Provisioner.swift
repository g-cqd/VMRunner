import Foundation
import Virtualization

/// Turns a freshly created `VMConfig` into a bootable machine: fetch media, lay out the bundle, install.
enum Provisioner {
    @MainActor
    static func run(config: VMConfig, library: VMLibrary, job: SetupJob) async throws {
        switch config.guest {
        case .linux: try await provisionLinux(config, library, job)
        case .macOS: try await provisionMac(config, library, job)
        }
    }

    /// Creates the machine's folder and a sparse disk image, unless a resumed setup already made them.
    @MainActor
    private static func createBundleAndDisk(for config: VMConfig, in bundle: VMBundle, job: SetupJob) throws {
        job.title = "Creating machine"
        job.fraction = nil
        // A machine deleted while its media was verifying must not be recreated on disk.
        try Task.checkCancellation()
        try bundle.create()
        if !FileManager.default.fileExists(atPath: bundle.disk.path) {
            try DiskImage.create(at: bundle.disk, gibibytes: config.diskGiB)
        }
    }

    // MARK: Linux

    @MainActor
    private static func provisionLinux(_ config: VMConfig, _ library: VMLibrary, _ job: SetupJob) async throws {
        var config = config
        let bundle = library.bundle(config.id)

        if let iso = try await resolveMedia(config.source, job: job) {
            config.installerISO = iso.path
            config.installerAttached = true
        }

        try createBundleAndDisk(for: config, in: bundle, job: job)
        _ = try VZEFIVariableStore(creatingVariableStoreAt: bundle.efiVariables, options: [.allowOverwrite])
        try VZGenericMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifier)

        config.isProvisioned = true
        library.update(config)
    }

    // MARK: macOS

    @MainActor
    private static func provisionMac(_ config: VMConfig, _ library: VMLibrary, _ job: SetupJob) async throws {
        var config = config
        let bundle = library.bundle(config.id)
        guard let ipsw = try await resolveMedia(config.source, job: job) else {
            throw SetupError.missingFile("macOS restore image")
        }

        job.title = "Reading restore image"
        job.fraction = nil
        let image = try await VZMacOSRestoreImage.image(from: ipsw)
        guard let requirements = image.mostFeaturefulSupportedConfiguration else {
            throw SetupError.unsupportedHost("This restore image can't run on this Mac.")
        }
        guard requirements.hardwareModel.isSupported else {
            throw SetupError.unsupportedHost("This host can't virtualize the hardware model required by this image.")
        }

        config.cpuCount = max(config.cpuCount, requirements.minimumSupportedCPUCount)
        config.memoryMiB = max(config.memoryMiB, Int(requirements.minimumSupportedMemorySize >> 20))
        let version = image.operatingSystemVersion
        config.guestVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion) (\(image.buildVersion))"

        try createBundleAndDisk(for: config, in: bundle, job: job)
        _ = try VZMacAuxiliaryStorage(
            creatingStorageAt: bundle.auxiliaryStorage, hardwareModel: requirements.hardwareModel, options: [.allowOverwrite])
        try requirements.hardwareModel.dataRepresentation.write(to: bundle.hardwareModel)
        try VZMacMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifier)
        library.update(config)

        // Installation must write to the real disk, never a disposable copy.
        var installConfig = config
        installConfig.ephemeral = false
        // The installer works from a local image; a user-mode stack here would have nobody to start and stop it.
        if installConfig.networkMode == .filtered { installConfig.networkMode = .none }
        let vz = try ConfigurationBuilder.build(installConfig, bundle: bundle).configuration
        let machine = VZVirtualMachine(configuration: vz)
        let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: ipsw)

        job.title = "Installing macOS \(version.majorVersion)"
        job.fraction = 0
        let observation = installer.progress.observe(\.fractionCompleted, options: [.new]) { _, change in
            guard let fraction = change.newValue else { return }
            Task { @MainActor in job.fraction = fraction }
        }
        defer { observation.invalidate() }

        try await withTaskCancellationHandler {
            try await installer.install()
        } onCancel: {
            installer.progress.cancel()
        }

        config.isProvisioned = true
        library.update(config)
        discardCachedRestoreImage(ipsw)
    }

    /// A restore image is 20+ GB and only needed once: cloning an installed machine is cheaper than reinstalling.
    /// Files the user picked themselves are never touched.
    private static func discardCachedRestoreImage(_ url: URL) {
        let keep = UserDefaults.standard.object(forKey: "keepsRestoreImages") as? Bool ?? false
        guard !keep, url.standardizedFileURL.path.hasPrefix(AppPaths.images.standardizedFileURL.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Media

    /// Resolves an `ImageSource` to a local file, downloading if needed.
    @MainActor
    private static func resolveMedia(_ source: ImageSource?, job: SetupJob) async throws -> URL? {
        switch source {
        case nil:
            return nil
        case .local(let path):
            guard FileManager.default.fileExists(atPath: path) else { throw SetupError.missingFile(path) }
            return URL(filePath: path)
        case .latestMac:
            job.title = "Looking up the latest supported macOS"
            job.fraction = nil
            let latest = try await VZMacOSRestoreImage.latestSupported
            return try await ImageStore.fetch(latest.url, checksum: nil, job: job)
        case .linuxCatalog(let id):
            guard let entry = LinuxCatalog.images.first(where: { $0.id == id }) else {
                throw SetupError.missingFile("catalog entry \(id)")
            }
            job.title = "Looking up the newest \(entry.name)"
            job.fraction = nil
            guard case .remote(let url, let checksum) = try await LinuxCatalog.resolve(entry) else { return nil }
            return try await ImageStore.fetch(url, checksum: checksum, job: job)
        case .remote(let url, let checksum):
            return try await ImageStore.fetch(url, checksum: checksum, job: job)
        }
    }
}
