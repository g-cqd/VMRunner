import Foundation

// A stand-in for arcleak, dolly and deadwood used by the DevToolsTests end-to-end suites. It is installed under the
// tool's name and answers only what the tooling asks of an analyzer:
//   every call                    appends "<name> <arguments>" to $FAKE_ANALYZER_LOG.<name> (one file per tool, so
//                                 concurrent installs never share a file), so a test can prove that a binary ran,
//                                 or that it never did
//   --version                     prints $FAKE_ANALYZER_VERSION
//   analyze ... [--write-baseline FILE]
//                                 writes FILE when asked, prints $FAKE_FINDINGS_<TOOL> warnings and one note in the
//                                 analyzers' diagnostic format, and exits with $FAKE_EXIT_<TOOL> (default 0)
let arguments = Array(CommandLine.arguments.dropFirst())
let name = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
let environment = ProcessInfo.processInfo.environment

if let base = environment["FAKE_ANALYZER_LOG"] {
    let path = "\(base).\(name)"
    let line = ([name] + arguments).joined(separator: " ") + "\n"
    if let handle = FileHandle(forWritingAtPath: path) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
    }
}
if arguments == ["--version"] {
    try? FileHandle.standardOutput.write(contentsOf: Data("\(environment["FAKE_ANALYZER_VERSION"] ?? "0.0.0")\n".utf8))
    exit(0)
}

if let flag = arguments.firstIndex(of: "--write-baseline"), flag + 1 < arguments.count {
    try? Data("{\"fingerprints\":[],\"tool\":\"\(name)\",\"version\":1}\n".utf8).write(to: URL(fileURLWithPath: arguments[flag + 1]))
}
for index in 0..<(Int(environment["FAKE_FINDINGS_\(name.uppercased())"] ?? "") ?? 0) {
    try? FileHandle.standardOutput.write(contentsOf: Data("Sources/A.swift:\(index + 1):1: warning: [fake] a finding\n".utf8))
}
if environment["FAKE_FINDINGS_\(name.uppercased())"] != nil {
    try? FileHandle.standardOutput.write(contentsOf: Data("Sources/A.swift:1:1: note: [fake] advice, not a finding\n".utf8))
}
exit(Int32(environment["FAKE_EXIT_\(name.uppercased())"] ?? "") ?? 0)
