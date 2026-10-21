// The way this plugin launches its tool (resolve it with `context.tool(named:)`, run it with `Process`, throw on a
// non-zero status so `swift package` exits non-zero) follows the command plugins of the aemi package
// (Plugins/Lint, MIT, Copyright (c) 2026 Aemi Studio); see THIRD_PARTY_LICENSES.
import Foundation
import PackagePlugin

/// `swift package analyzers [run|install|baseline|versions|pins] [tool...]`: forwards to `vmr analyzers` for this package.
@main
struct AnalyzersPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let vmr = try context.tool(named: "vmr")
        let process = Process()
        process.executableURL = vmr.url
        process.arguments = ["analyzers"] + arguments + ["--root", context.package.directoryURL.path(percentEncoded: false)]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PluginError.failed(status: process.terminationStatus)
        }
    }
}

private enum PluginError: Error, CustomStringConvertible {
    case failed(status: Int32)

    var description: String {
        switch self {
        case .failed(let status): "vmr analyzers exited with status \(status)"
        }
    }
}
