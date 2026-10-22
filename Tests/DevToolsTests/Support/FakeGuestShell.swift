import Foundation
import GuestConsole
import Synchronization

/// A console served by the real bridge, with a fake guest behind it: a getty that takes any user name, then a shell that
/// understands the exec protocol's line (`echo MARK_S_<n>; <command>; echo MARK_E_<n>_$?`) and answers a few commands.
///
/// The end-to-end tests run the real `vmr guest exec` against its socket.
final class FakeGuestConsole: Sendable {
    let socket: String
    private let bridge: ConsoleBridge
    private let stop = Stop()
    private let guestDescriptor: Int32

    private final class Stop: Sendable {
        let requested = Mutex(false)
    }

    /// Commands the fake shell knows: its output and exit status. Any other command prints "not found" and exits 127.
    static let commands: [String: (output: String, status: Int)] = [
        "uname -a": ("Linux localhost 6.18.52-0-virt aarch64 Linux\n", 0),
        "fail": ("it failed\n", 3),
        "silence": ("", 0),
    ]

    /// `socketPath` is in a directory the caller made private. A command named `hang` never gets an answer.
    init(socketPath: String) throws {
        let pair = try ConsoleBridge.makeGuestPair()
        do {
            bridge = try ConsoleBridge(guestDescriptor: pair.host, socketPath: socketPath)
        } catch {
            close(pair.host)
            close(pair.guest)
            throw error
        }
        socket = socketPath
        guestDescriptor = pair.guest
        let descriptor = pair.guest
        let stop = stop
        bridge.start()
        let thread = Thread { Self.serve(descriptor, stop: stop) }
        thread.name = "FakeGuestConsole"
        thread.start()
    }

    func shutDown() async {
        stop.requested.withLock { $0 = true }
        bridge.stop()
        await bridge.waitUntilFinished()
        close(guestDescriptor)
    }

    // MARK: The guest

    private static func serve(_ descriptor: Int32, stop: Stop) {
        send(descriptor, "Welcome to the fake guest\r\nlocalhost login: ")
        var loggedIn = false
        var pending: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while !stop.requested.withLock({ $0 }) {
            var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard unsafe poll(&entry, 1, 20) > 0 else { continue }
            let count = buffer.withUnsafeMutableBytes { unsafe read(descriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(bytes: pending[0..<newline], encoding: .utf8) ?? ""
                pending.removeSubrange(0...newline)
                if !loggedIn {
                    loggedIn = true
                    send(descriptor, "\(line)\r\nlocalhost:~# ")
                } else if let reply = answer(line) {
                    send(descriptor, reply)
                }
            }
        }
    }

    /// The terminal's answer to an exec line: the echo, both markers around the output, and the next prompt.
    private static func answer(_ line: String) -> String? {
        let start = "echo MARK_S_"
        guard line.hasPrefix(start), let separator = line.firstIndex(of: ";"),
            let tail = line.range(of: "; echo MARK_E_", options: .backwards)
        else {
            return line + "\r\nlocalhost:~# "
        }
        let nonce = line[line.index(line.startIndex, offsetBy: start.count)..<separator]
        let command = String(line[line.index(separator, offsetBy: 2)..<tail.lowerBound])
        if command == "hang" { return nil }
        let outcome = commands[command] ?? ("sh: \(command): not found\n", 127)
        return line + "\r\nMARK_S_\(nonce)\r\n" + outcome.output.replacing("\n", with: "\r\n")
            + "MARK_E_\(nonce)_\(outcome.status)\r\nlocalhost:~# "
    }

    private static func send(_ descriptor: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { unsafe write(descriptor, $0.baseAddress, $0.count) }
            if count > 0 { sent += count } else if count < 0, errno != EINTR { return }
        }
    }
}
