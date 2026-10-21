import Foundation

/// A fresh empty directory under the system temporary folder. Callers remove it when done.
func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "vmrunner-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
