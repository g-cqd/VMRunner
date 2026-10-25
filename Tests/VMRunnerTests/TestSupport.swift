import Foundation
import Virtualization

/// A fresh empty directory under the system temporary folder. Callers remove it when done.
func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "vmrunner-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Puts a real, empty EFI variable store at `url`, as machine creation does. A test that stands in for a machine's firmware
/// variables uses this and not made-up bytes: once the framework has been asked about a file that is not a store, every later
/// store operation in the same process fails with an EFI error, whichever test makes it.
func writeEFIVariableStore(at url: URL) throws {
    _ = try VZEFIVariableStore(creatingVariableStoreAt: url, options: [.allowOverwrite])
}
