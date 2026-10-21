import ContainerSpikeCore
import Foundation

let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let request: SpikeRequest
do {
    request = try SpikeArguments.parse(Array(CommandLine.arguments.dropFirst()), currentDirectory: currentDirectory)
} catch {
    Console.line("error: \(error)", to: .error)
    Console.line(SpikeArguments.usage, to: .error)
    exit(SpikeStatus.usage)
}

switch request {
case .help:
    Console.line(SpikeArguments.usage)
    exit(SpikeStatus.passed)
case .run(let arguments):
    exit(await SpikeMain.run(arguments))
}
