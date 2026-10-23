import Foundation

/// A private (0700) folder for one test, removed by `cleanUp()`. Never the app's data folder. A socket test passes `/tmp` as
/// `root`: a local socket path holds at most 103 bytes, and the usual temporary folder is longer than that.
struct ScratchFolder: Sendable {
    let url: URL

    init(in root: URL = FileManager.default.temporaryDirectory) throws {
        url = root.appending(path: "control-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func cleanUp() { try? FileManager.default.removeItem(at: url) }
}
