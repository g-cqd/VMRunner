import Foundation

/// Where the installation media comes from.
enum ImageSource: Codable, Hashable, Sendable {
    /// Whatever `VZMacOSRestoreImage.latestSupported` points at.
    case latestMac
    /// Newest ISO of a `LinuxCatalog` entry, resolved when setup runs.
    case linuxCatalog(id: String)
    case remote(URL, checksum: Checksum?)
    case local(String)
}
