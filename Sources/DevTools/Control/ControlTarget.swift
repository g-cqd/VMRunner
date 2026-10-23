import ControlProtocol
import Foundation
import GuestConsole

/// The exit statuses of `vmr control`, from `sysexits.h` where one fits, besides 0 (done) and `ToolError.usageStatus` (64: a
/// bad argument, no token, or a token that is not one).
enum ControlExit {
    /// The service answered the call with an error other than the ones below.
    static let refused: Int32 = 1
    /// The token file is missing or cannot be read (`EX_NOINPUT`).
    static let noInput: Int32 = 66
    /// Nothing serves the socket: the service is off or the app is not running (`EX_UNAVAILABLE`).
    static let unavailable: Int32 = 69
    /// No answer in time, or the service's own -32005 (`EX_TEMPFAIL`): what the call started may still finish.
    static let timedOut: Int32 = 75
    /// An answer this client cannot read, or none (`EX_PROTOCOL`).
    static let protocolError: Int32 = 76
    /// The token lacks the right (-32001), the token file is open to other users, or the socket is another user's
    /// (`EX_NOPERM`).
    static let notPermitted: Int32 = 77
}

/// Where `vmr control` finds the service and the token it presents.
enum ControlTarget {
    /// The environment variable a token can be given in. A token is never an argument: `ps` shows arguments to every user.
    static let tokenVariable = "VMR_CONTROL_TOKEN"
    /// The app's own variable for another data folder (CONTRIBUTING, `VMRUNNER_DATA_DIR`).
    static let dataDirectoryVariable = "VMRUNNER_DATA_DIR"
    /// A token file is at most this long; a token is 69 characters.
    static let tokenFileBytes = 4_096

    /// `socket` when given (relative to `currentDirectory`), otherwise `Control/control.sock` in the app's data folder: the one
    /// `VMRUNNER_DATA_DIR` names when it is set and not empty, otherwise `Library/Application Support/VMRunner` in `home`.
    static func socketPath(_ socket: String?, environment: [String: String], home: URL, currentDirectory: URL) throws -> String {
        if let socket {
            return URL(fileURLWithPath: socket, relativeTo: currentDirectory).standardizedFileURL.path
        }
        let data: URL
        if let override = environment[dataDirectoryVariable], !override.isEmpty {
            guard override.hasPrefix("/"), !override.split(separator: "/").contains("..") else {
                throw ToolError.usage("\(dataDirectoryVariable) must be an absolute path without `..`: \(override)")
            }
            data = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        } else {
            data = home.appending(path: "Library/Application Support/VMRunner", directoryHint: .isDirectory)
        }
        return data.appending(path: "Control/control.sock").path
    }

    /// The token: the contents of `file` when given (relative to `currentDirectory`), otherwise `VMR_CONTROL_TOKEN`; nil when
    /// neither is given. A file must be a regular file of this user that no other user may read or write, like a private
    /// key.
    static func token(file: String?, environment: [String: String], currentDirectory: URL) throws -> String? {
        if let file {
            return try checked(try contents(of: URL(fileURLWithPath: file, relativeTo: currentDirectory).standardizedFileURL), from: file)
        }
        guard let text = environment[tokenVariable], !text.isEmpty else { return nil }
        return try checked(text, from: tokenVariable)
    }

    /// The token, or a usage error that says how to give one.
    static func requiredToken(file: String?, environment: [String: String], currentDirectory: URL) throws -> String {
        guard let token = try token(file: file, environment: environment, currentDirectory: currentDirectory) else {
            throw ToolError.usage("no token: give --token-file FILE or set \(tokenVariable)")
        }
        return token
    }

    private static func contents(of url: URL) throws -> String {
        // `attributesOfItem` describes a link itself and does not follow it.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            throw ToolError("cannot read the token file \(url.path)", status: ControlExit.noInput)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ToolError("the token file \(url.path) is not a regular file", status: ControlExit.noInput)
        }
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw ToolError("the token file \(url.path) belongs to another user", status: ControlExit.notPermitted)
        }
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        guard mode & 0o077 == 0 else {
            let shown = String(mode & 0o777, radix: 8)
            throw ToolError(
                "the token file \(url.path) is open to other users (mode \(shown)); make it private: chmod 600 \(url.path)",
                status: ControlExit.notPermitted)
        }
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= tokenFileBytes,
            let data = try? Data(contentsOf: url), data.count <= tokenFileBytes, let text = String(bytes: data, encoding: .utf8)
        else {
            throw ToolError(
                "cannot read the token file \(url.path) as text, or it is longer than \(tokenFileBytes) bytes", status: ControlExit.noInput)
        }
        return text
    }

    private static func checked(_ text: String, from source: String) throws -> String {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix(ControlSecret.prefix), !token.contains(where: \.isWhitespace) else {
            throw ToolError.usage("\(source) does not hold a control token (one starts with \(ControlSecret.prefix))")
        }
        return token
    }
}

/// How `vmr control` reports an error thrown while calling the service: a message and an exit status.
enum ControlFailure {
    static func toolError(_ error: any Error, socket: String) -> ToolError {
        switch error {
        case ConsoleError.notServed:
            ToolError(
                "nothing serves \(socket): the control service is off (VMRunner's Settings, Automation) or the app is not running",
                status: ControlExit.unavailable)
        case let error as ConsoleError:
            ToolError("cannot reach \(socket): \(error)", status: ControlExit.unavailable)
        case ControlClientError.timedOut:
            ToolError("\(error); what the call started may still finish", status: ControlExit.timedOut)
        case ControlClientError.peerIsAnotherUser:
            ToolError("\(socket): \(error)", status: ControlExit.notPermitted)
        default:
            ToolError("\(error)", status: ControlExit.protocolError)
        }
    }

    /// The exit status for an error the service answered with.
    static func status(forCode code: Int) -> Int32 {
        switch code {
        case RPCError.notPermitted.code: ControlExit.notPermitted
        case RPCError.timedOut.code: ControlExit.timedOut
        default: ControlExit.refused
        }
    }
}
