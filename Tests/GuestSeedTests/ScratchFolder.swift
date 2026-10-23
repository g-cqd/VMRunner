import Foundation

/// A new, empty folder under the temporary directory for one test; the test removes it when it ends.
func makeScratchFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(
        path: "provisioning-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}
