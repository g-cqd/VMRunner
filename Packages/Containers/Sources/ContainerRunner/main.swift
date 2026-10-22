import ContainerRunnerCore
import Foundation

let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let request: RunnerRequest
do {
    request = try RunnerArguments.parse(Array(CommandLine.arguments.dropFirst()), currentDirectory: currentDirectory)
} catch {
    Console.line("error: \(error)", to: .error)
    Console.line(RunnerArguments.usage, to: .error)
    exit(RunnerStatus.usage)
}

switch request {
case .help:
    Console.line(RunnerArguments.usage)
    exit(RunnerStatus.passed)
case .run(let arguments):
    exit(await RunnerMain.run(arguments))
}
