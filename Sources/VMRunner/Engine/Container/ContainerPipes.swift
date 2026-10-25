import Darwin
import Foundation
import Synchronization

/// How many descriptors a run holds open: each end of each pipe is counted when it is opened and when it is closed. A test reads
/// it to see that a run leaves none behind; the system's own table cannot say that while other suites open files.
final class DescriptorLedger: Sendable {
    private let open = Mutex(0)

    var count: Int { open.withLock { $0 } }

    func opened(_ number: Int = 1) { open.withLock { $0 += number } }

    func closed() { open.withLock { $0 -= 1 } }

    /// Closes a descriptor this ledger counted.
    func close(_ descriptor: Int32) {
        _ = Darwin.close(descriptor)
        closed()
    }
}

/// The three pipes of one run: six ends, every one close-on-exec, so no other child this app starts inherits one. The runner
/// gets its three ends through the spawn's own descriptor setup. The driver closes its copies of the runner's ends as soon as
/// the runner has them, and keeps the other three: the write end of the input, and the two read ends it follows.
struct RunnerPipes {
    /// The write end of the runner's standard input.
    let input: FileHandle
    let inputRead: Int32
    let outputRead: Int32
    let outputWrite: Int32
    let errorRead: Int32
    let errorWrite: Int32
    let ledger: DescriptorLedger

    /// Opens the pipes; nil when the system refuses, with nothing left open.
    init?(ledger: DescriptorLedger) {
        guard let standardInput = Self.makePipe() else { return nil }
        guard let standardOutput = Self.makePipe() else {
            Self.discard(standardInput)
            return nil
        }
        guard let standardError = Self.makePipe() else {
            Self.discard(standardInput)
            Self.discard(standardOutput)
            return nil
        }
        input = FileHandle(fileDescriptor: standardInput.write, closeOnDealloc: true)
        inputRead = standardInput.read
        outputRead = standardOutput.read
        outputWrite = standardOutput.write
        errorRead = standardError.read
        errorWrite = standardError.write
        self.ledger = ledger
        ledger.opened(6)
    }

    /// Gives the process the runner's three ends as its standard streams. They stay owned by this value.
    func connect(_ process: Process) {
        process.standardInput = FileHandle(fileDescriptor: inputRead, closeOnDealloc: false)
        process.standardOutput = FileHandle(fileDescriptor: outputWrite, closeOnDealloc: false)
        process.standardError = FileHandle(fileDescriptor: errorWrite, closeOnDealloc: false)
    }

    /// Closes the ends the runner has its own copies of: left open they would keep the pipes open after the runner is gone.
    func closeChildEnds() {
        for descriptor in [inputRead, outputWrite, errorWrite] { ledger.close(descriptor) }
    }

    /// Closes the two read ends: for a run that did not start, before anything follows them.
    func closeReadEnds() {
        for descriptor in [outputRead, errorRead] { ledger.close(descriptor) }
    }

    /// Closes the write end of the input: for a run that did not start, before a handle took it over.
    func closeInput() {
        try? input.close()
        ledger.closed()
    }

    private static func makePipe() -> (read: Int32, write: Int32)? {
        var ends: [Int32] = [-1, -1]
        guard unsafe pipe(&ends) == 0 else { return nil }
        let pair = (read: ends[0], write: ends[1])
        guard fcntl(pair.read, F_SETFD, FD_CLOEXEC) == 0, fcntl(pair.write, F_SETFD, FD_CLOEXEC) == 0 else {
            discard(pair)
            return nil
        }
        return pair
    }

    private static func discard(_ pair: (read: Int32, write: Int32)) {
        _ = Darwin.close(pair.read)
        _ = Darwin.close(pair.write)
    }
}
