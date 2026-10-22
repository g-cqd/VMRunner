import Foundation
import GuestConsole

/// Where a machine's serial console is served: the socket and the folder that holds it.
///
/// The socket belongs in the machine's bundle (`Console.sock`, in a folder only the user can enter, next to the machine's
/// other private files). A local socket path holds at most 103 bytes, though, and the bundle of a machine in the usual
/// place is longer than that, so then the socket goes in a private folder of the user's temporary directory under a short
/// name made from the machine's identifier.
struct ConsoleSocketPlacement: Equatable {
    static let socketName = "Console.sock"
    static let shortFolderName = "VMRunner-console"
    /// How much of the machine's identifier names the socket when the bundle's path is too long.
    static let shortNameLength = 12

    let path: String
    /// The folder the socket is created in. It must be private to the user: the bridge refuses any other.
    let directory: String
}

extension VMBundle {
    /// The placement of this machine's console socket. `shortFolder` is the folder used when the bundle's path is too long.
    func consoleSocket(shortFolder: URL = FileManager.default.temporaryDirectory) -> ConsoleSocketPlacement {
        let inBundle = url.appending(path: ConsoleSocketPlacement.socketName).path
        if inBundle.utf8.count <= ConsoleBridge.socketPathLimit { return ConsoleSocketPlacement(path: inBundle, directory: url.path) }
        let folder = shortFolder.appending(path: ConsoleSocketPlacement.shortFolderName, directoryHint: .isDirectory).path
        let name = url.deletingPathExtension().lastPathComponent.lowercased().prefix(ConsoleSocketPlacement.shortNameLength)
        return ConsoleSocketPlacement(path: "\(folder)/\(name).sock", directory: folder)
    }
}
