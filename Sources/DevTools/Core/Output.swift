import Foundation

/// Writes command-line output straight to the standard streams.
///
/// Every write goes to the file descriptor immediately, so it interleaves correctly with the output of child
/// processes that inherit the same descriptors.
enum Output {
    static func out(_ text: String = "") {
        write(text + "\n", to: .standardOutput)
    }

    static func err(_ text: String) {
        write(text + "\n", to: .standardError)
    }

    private static func write(_ text: String, to handle: FileHandle) {
        try? handle.write(contentsOf: Data(text.utf8))
    }
}
