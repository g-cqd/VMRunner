import Foundation

/// The entries of one map of the spec, each key checked against the ones its section allows.
struct SpecFields {
    /// The line of the map's first key.
    let line: Int
    private let entries: [SpecEntry]
    private let section: String

    init(_ node: SpecNode, section: String, allowed: Set<String>) throws {
        guard case .map(let entries, let line) = node else {
            throw ProvisioningError(line: node.line, "\(section) must be a map of keys")
        }
        if let unknown = entries.first(where: { !allowed.contains($0.key) }) {
            let known = allowed.sorted().joined(separator: ", ")
            throw ProvisioningError(line: unknown.line, "\(section) has no field \(unknown.key); it takes \(known)")
        }
        self.line = line
        self.entries = entries
        self.section = section
    }

    /// The value of `key`, or nil when the map does not have it.
    func value(for key: String) -> SpecNode? {
        entries.first { $0.key == key }?.value
    }

    /// The value of `key`, which must be there.
    func required(_ key: String) throws -> SpecNode {
        guard let found = value(for: key) else { throw ProvisioningError(line: line, "\(section) needs \(key)") }
        return found
    }

    /// The text of `key`, or nil when the map does not have it; a map or a list there is refused.
    func optionalText(_ key: String) throws -> SpecText? {
        guard let found = value(for: key) else { return nil }
        guard case .text(let text, let line) = found else {
            throw ProvisioningError(line: found.line, "\(section).\(key) must be text")
        }
        return SpecText(text: text, line: line)
    }

    /// The text of `key`, which must be there.
    func text(_ key: String) throws -> SpecText {
        guard let found = try optionalText(key) else { throw ProvisioningError(line: line, "\(section) needs \(key)") }
        return found
    }
}

extension ProvisioningSpec {
    /// Reads and checks a spec, refusing it at the first problem with the line it is on.
    package init(parsing text: String, limits: ProvisioningLimits = .standard) throws {
        let root = try SpecFields(
            try SpecReader.read(text, limits: limits), section: "the spec", allowed: ["apiVersion", "kind", "metadata", "spec"])
        let apiVersion = try root.text("apiVersion")
        guard apiVersion.text == Self.apiVersion else {
            throw ProvisioningError(line: apiVersion.line, "apiVersion must be \(Self.apiVersion)")
        }
        let kind = try root.text("kind")
        guard kind.text == Self.kind else { throw ProvisioningError(line: kind.line, "kind must be \(Self.kind)") }
        let metadata = try SpecFields(try root.required("metadata"), section: "metadata", allowed: ["name"])
        let name = try metadata.text("name")
        guard Self.isHostName(name.text) else {
            throw ProvisioningError(
                line: name.line, "metadata.name must be a DNS label: lowercase letters, digits and inner hyphens, 63 at most")
        }
        let spec = try SpecFields(try root.required("spec"), section: "spec", allowed: ["cloudInit", "provision"])
        var cloudInit = CloudInitSource()
        if let section = spec.value(for: "cloudInit") { cloudInit = try Self.cloudInit(section) }
        var steps: [ProvisioningStep] = []
        if let list = spec.value(for: "provision") { steps = try Self.steps(list, limits: limits) }
        guard cloudInit.userData != nil || !steps.isEmpty else {
            throw ProvisioningError(line: spec.line, "spec needs cloudInit.userData or at least one provision step")
        }
        self.init(name: name.text, cloudInit: cloudInit, steps: steps)
    }

    private static func isHostName(_ name: String) -> Bool {
        (1...63).contains(name.utf8.count) && name.first != "-" && name.last != "-"
            && name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }

    private static func cloudInit(_ node: SpecNode) throws -> CloudInitSource {
        let fields = try SpecFields(
            node, section: "cloudInit",
            allowed: ["userData", "userDataBase64", "networkData", "networkDataBase64", "secretRef", "networkDataSecretRef"])
        if let key = ["secretRef", "networkDataSecretRef"].first(where: { fields.value(for: $0) != nil }),
            let found = fields.value(for: key)
        {
            throw ProvisioningError(line: found.line, "cloudInit.\(key) is not supported: a secret never goes into the seed")
        }
        return CloudInitSource(
            userData: try passThrough(fields, plain: "userData", encoded: "userDataBase64"),
            networkData: try passThrough(fields, plain: "networkData", encoded: "networkDataBase64"))
    }

    /// A plain field or its base64 twin, decoded; both at once are refused.
    private static func passThrough(_ fields: SpecFields, plain: String, encoded: String) throws -> SpecText? {
        let given = try fields.optionalText(plain)
        guard let base64 = try fields.optionalText(encoded) else { return given }
        guard given == nil else { throw ProvisioningError(line: base64.line, "cloudInit takes \(plain) or \(encoded), not both") }
        let compact = base64.text.filter({ $0 != "\n" })
        guard let data = Data(base64Encoded: compact), let decoded = String(data: data, encoding: .utf8) else {
            throw ProvisioningError(line: base64.line, "cloudInit.\(encoded) is not base64 of UTF-8 text")
        }
        return SpecText(text: decoded, line: base64.line)
    }

    private static func steps(_ node: SpecNode, limits: ProvisioningLimits) throws -> [ProvisioningStep] {
        guard case .list(let items, _) = node else {
            throw ProvisioningError(line: node.line, "provision must be a list of steps")
        }
        if items.count > limits.maxSteps {
            throw ProvisioningError(line: items[limits.maxSteps].line, "more than \(limits.maxSteps) steps")
        }
        return try items.map { try step($0) }
    }

    private static func step(_ node: SpecNode) throws -> ProvisioningStep {
        let fields = try SpecFields(node, section: "a step", allowed: ["at", "user", "script", "file", "sha256", "env"])
        let at = try fields.text("at")
        guard let phase = ProvisioningPhase(rawValue: at.text) else {
            let phases = ProvisioningPhase.allCases.map(\.rawValue).joined(separator: ", ")
            throw ProvisioningError(line: at.line, "at must be one of \(phases)")
        }
        let user = try fields.optionalText("user")
        guard let runsAs = StepUser(rawValue: user?.text ?? "system") else {
            throw ProvisioningError(line: user?.line ?? fields.line, "user must be system or user")
        }
        var variables: [StepVariable] = []
        var secrets: [SecretVariable] = []
        if let env = fields.value(for: "env") { (variables, secrets) = try environment(env) }
        return ProvisioningStep(
            line: fields.line, phase: phase, user: runsAs, script: try script(fields), variables: variables, secrets: secrets)
    }

    private static func script(_ fields: SpecFields) throws -> StepScript {
        let inline = try fields.optionalText("script")
        let file = try fields.optionalText("file")
        let sha256 = try fields.optionalText("sha256")
        switch (inline, file) {
        case (let text?, nil):
            if let sha256 { throw ProvisioningError(line: sha256.line, "sha256 goes with file, not with script") }
            guard text.text.hasPrefix("#!") else {
                throw ProvisioningError(line: text.line, "a script starts with #! and its interpreter")
            }
            return .inline(text.text)
        case (nil, let path?):
            guard isRelativePath(path.text) else {
                throw ProvisioningError(line: path.line, "file must be a relative path inside the spec's folder, without . or .. parts")
            }
            guard let sha256 else { throw ProvisioningError(line: path.line, "a file needs its sha256") }
            guard sha256.text.count == 64, sha256.text.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }) else {
                throw ProvisioningError(line: sha256.line, "sha256 must be 64 lowercase hexadecimal digits")
            }
            return .file(path: path.text, sha256: sha256.text)
        default:
            throw ProvisioningError(line: fields.line, "a step needs either script or file")
        }
    }

    /// Letters, digits, `.`, `_`, `-` and `/` only, at most 255 bytes, every part non-empty and none of them `.` or `..`.
    private static func isRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return path.utf8.count <= 255 && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
            && path.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" || $0 == "/") }
    }

    private static func environment(_ node: SpecNode) throws -> ([StepVariable], [SecretVariable]) {
        guard case .map(let entries, _) = node else { throw ProvisioningError(line: node.line, "env must be a map of variables") }
        var variables: [StepVariable] = []
        var secrets: [SecretVariable] = []
        for entry in entries {
            guard isVariableName(entry.key) else {
                throw ProvisioningError(line: entry.line, "\(entry.key) is not a variable name: letters, digits and _, not a digit first")
            }
            switch entry.value {
            case .text(let value, _):
                guard !value.unicodeScalars.contains(where: isControlOrLineBreak) else {
                    throw ProvisioningError(line: entry.line, "the value of \(entry.key) must be one line without control characters")
                }
                variables.append(StepVariable(name: entry.key, value: value))
            case .map:
                let reference = try SpecFields(entry.value, section: "env.\(entry.key)", allowed: ["secretRef"])
                let secretName = try reference.text("secretRef")
                guard !secretName.text.isEmpty else { throw ProvisioningError(line: secretName.line, "secretRef needs a name") }
                secrets.append(SecretVariable(name: entry.key, secretName: secretName.text))
            case .list:
                throw ProvisioningError(line: entry.line, "the value of \(entry.key) is text or a map with secretRef")
            }
        }
        return (variables, secrets)
    }

    /// A control character, a character YAML 1.1 reads as a line break (U+0085, U+2028, U+2029) or one its readers reject
    /// (U+FFFE, U+FFFF): the value would not reach the guest as written, or the guest would drop the whole cloud-config.
    private static func isControlOrLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) || [0x2028, 0x2029, 0xFFFE, 0xFFFF].contains(scalar.value)
    }

    private static func isVariableName(_ name: String) -> Bool {
        guard let first = name.first, !first.isNumber else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
}
