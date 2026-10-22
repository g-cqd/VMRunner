import Foundation
import Testing

/// A preferences suite of its own for one test, which leaves nothing in `~/Library/Preferences`. A suite named like a
/// domain keeps its file there, and emptying it with `removePersistentDomain(forName:)` does not delete the file: the
/// system writes the empty domain back (42 bytes) a few seconds later, even after the file was deleted. A suite named by
/// an absolute path keeps its file at that path instead, so this suite lives in a scratch folder that `cleanUp()` removes.
struct ScratchDefaults {
    /// The suite's name: an absolute path in the scratch folder, without the `.plist` the system adds.
    let name: String
    let defaults: UserDefaults
    private let folder: URL

    init() throws {
        folder = try scratchDirectory()
        name = folder.appending(path: "defaults").path
        guard let defaults = UserDefaults(suiteName: name) else {
            try? FileManager.default.removeItem(at: folder)
            throw CocoaError(.featureUnsupported)
        }
        self.defaults = defaults
    }

    /// The file the system keeps the suite's values in, once something was written.
    var file: URL { URL(filePath: name + ".plist") }

    /// Empties the suite and removes its folder, with the file in it.
    func cleanUp() {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: folder)
    }
}

/// The helper itself: the suite's file is written in its scratch folder, not in the user's preferences, and is gone after
/// the clean-up.
struct ScratchDefaultsTests {
    @Test func theSuiteKeepsItsFileOutOfThePreferencesFolderAndCleanUpRemovesIt() throws {
        let scratch = try ScratchDefaults()
        scratch.defaults.set(true, forKey: "written")
        scratch.defaults.synchronize()
        #expect(FileManager.default.fileExists(atPath: scratch.file.path), "the value is on disk before the clean-up")
        let preferences = URL.libraryDirectory.appending(path: "Preferences", directoryHint: .isDirectory).path
        #expect(!scratch.file.path.hasPrefix(preferences))
        scratch.cleanUp()
        #expect(!FileManager.default.fileExists(atPath: scratch.file.path))
        #expect(!FileManager.default.fileExists(atPath: scratch.file.deletingLastPathComponent().path), "the folder is gone too")
    }
}
