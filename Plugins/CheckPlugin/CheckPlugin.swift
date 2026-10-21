// This plugin resolves its tool with `context.tool(named:)`, runs it with `Process`, and throws on a non-zero
// status so `swift package` exits non-zero.
import Foundation
import PackagePlugin

/// `swift package check [--full] [--list] [step...]`: forwards to `vmr check` for this package.
@main
struct CheckPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let vmr = try context.tool(named: "vmr")
        let process = Process()
        process.executableURL = vmr.url
        process.arguments = ["check"] + arguments + ["--root", context.package.directoryURL.path(percentEncoded: false)]
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
        case .failed(let status): "vmr check exited with status \(status)"
        }
    }
}
