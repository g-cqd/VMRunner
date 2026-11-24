import CryptoKit
import Foundation
import Virtualization
import os

/// A prepared capability prerequisite, not an arbitrary caller-supplied path. Creation verifies the embedded owned firmware.
struct WindowsBootMedia: Sendable {
    let url: URL
    let token: Data
    let variables: URL

    private init(url: URL, token: Data, variables: URL) {
        self.url = url
        self.token = token
        self.variables = variables
    }

    @concurrent static func prepare(in bundle: VMBundle) async throws -> Self {
        try prepareSynchronously(in: bundle)
    }

    static func prepareSynchronously(in bundle: VMBundle) throws -> Self {
        guard let firmware = Data(base64Encoded: WindowsBootFirmwareData.base64, options: .ignoreUnknownCharacters),
            SHA256.hash(data: firmware).map({ ($0 < 16 ? "0" : "") + String($0, radix: 16) }).joined() == WindowsBootFirmwareData.sha256
        else {
            throw SetupError.requiredCapabilityUnavailable(
                guest: .windows, capability: "framebuffer bootstrap", reason: "embedded firmware failed verification")
        }
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let token = Data(stride(from: 0, to: 32, by: 2).compactMap { UInt8(hex.dropFirst($0).prefix(2), radix: 16) })
        let image = try WindowsBootDisk.make(firmware: firmware, token: token)
        let url = bundle.windowsBootImage
        try image.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        // A separate per-start store guarantees firmware cannot follow a pre-existing Windows BootOrder around the shim.
        // Never overwrite the owner's original EFI store. The shim maintains BootNext for in-guest reboots.
        let variables = bundle.windowsBootVariables
        _ = try VZEFIVariableStore(creatingVariableStoreAt: variables, options: [.allowOverwrite])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: variables.path)
        Log.machine.notice("Prepared Windows bootstrap \(WindowsBootFirmwareData.sha256, privacy: .public)")
        Log.machine.info("Windows bootstrap source \(WindowsBootFirmwareData.sourceSHA256, privacy: .public)")
        return Self(url: url, token: token, variables: variables)
    }
}
