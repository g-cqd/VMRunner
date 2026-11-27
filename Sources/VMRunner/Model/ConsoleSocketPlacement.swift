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
        socketPlacement(named: ConsoleSocketPlacement.socketName, shortSuffix: "", shortFolder: shortFolder)
    }

    /// The placement of the local socket that forwards guest vsock `port`. `shortFolder` is as for ``consoleSocket(shortFolder:)``.
    func vsockForward(port: UInt32, shortFolder: URL = FileManager.default.temporaryDirectory) -> VsockForwardPlacement {
        socketPlacement(named: "Vsock-\(port).sock", shortSuffix: "-vsock-\(port)", shortFolder: shortFolder)
    }

    /// `name` in the bundle when that path fits a local socket, else `<machine><shortSuffix>.sock` in the private short folder.
    private func socketPlacement(named name: String, shortSuffix: String, shortFolder: URL) -> ConsoleSocketPlacement {
        let inBundle = url.appending(path: name).path
        if inBundle.utf8.count <= ConsoleBridge.socketPathLimit { return ConsoleSocketPlacement(path: inBundle, directory: url.path) }
        let folder = shortFolder.appending(path: ConsoleSocketPlacement.shortFolderName, directoryHint: .isDirectory).path
        let machine = url.deletingPathExtension().lastPathComponent.lowercased().prefix(ConsoleSocketPlacement.shortNameLength)
        return ConsoleSocketPlacement(path: "\(folder)/\(machine)\(shortSuffix).sock", directory: folder)
    }
}

/// Where a forwarded guest vsock port is served: `Vsock-<port>.sock` in the machine's bundle, or, when that path is too long
/// for a local socket, `<machine>-vsock-<port>.sock` in the console's private short folder.
typealias VsockForwardPlacement = ConsoleSocketPlacement
