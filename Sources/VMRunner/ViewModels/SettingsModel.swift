import AppKit
import Foundation
import Observation
import os

/// State and actions behind the Settings window.
@MainActor @Observable
final class SettingsModel {
    private(set) var cacheBytes: Int64 = 0
    var confirmingClear = false

    func refresh() async {
        let images = AppPaths.images
        cacheBytes = await Task.detached(priority: .utility) { Self.allocatedBytes(in: images) }.value
    }

    func clearImages() async {
        do {
            try FileManager.default.removeItem(at: AppPaths.images)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Nothing cached yet.
        } catch {
            Log.storage.error("Couldn't clear images: \(error.localizedDescription, privacy: .public)")
        }
        await refresh()
    }

    func revealImages() { reveal(AppPaths.images) }
    func revealMachines() { reveal(AppPaths.machines) }

    private func reveal(_ directory: URL) {
        do {
            try AppPaths.createPrivateDirectory(directory)
        } catch {
            Log.storage.error(
                "Couldn't create \(directory.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    nonisolated private static func allocatedBytes(in url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey]
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: keys).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
