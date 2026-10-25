import Foundation

/// A container's settings while they are typed: the command and the environment are text until they are read back into a
/// `ContainerSpec`. The New Machine sheet and the editor of a stored machine both go through it, so the same text gives the
/// same settings and the same refusals.
struct ContainerDraft: Equatable {
    var spec: ContainerSpec
    var commandLine: String
    var environmentText: String
    /// Whether the command and the environment can be edited as text. It is false when the stored command or environment does not
    /// survive being written as text and read back (an argument with a double quote, a value with a carriage return): editing
    /// the text would change what is stored, so the draft then keeps the stored command and environment as they are.
    let textIsEditable: Bool

    /// A draft of text the user typed, which `applied(to:)` reads.
    init(spec: ContainerSpec, commandLine: String, environmentText: String) {
        self.spec = spec
        self.commandLine = commandLine
        self.environmentText = environmentText
        textIsEditable = true
    }

    /// A draft of a stored spec, showing its command and environment as text.
    init(_ spec: ContainerSpec) {
        self.spec = spec
        commandLine = ContainerInput.line(from: spec.command)
        environmentText = ContainerInput.text(from: spec.environment)
        textIsEditable =
            (try? ContainerInput.arguments(from: commandLine)) == spec.command
            && (try? ContainerInput.environment(from: environmentText)) == spec.environment
    }

    /// `config` with the draft's settings, checked by the same rules a stored configuration is. Throws the reason the text or
    /// the settings cannot be used; read it with `VMConfig.reason(for:)`.
    func applied(to config: VMConfig) throws -> VMConfig {
        var settings = spec
        settings.image = settings.image.trimmingCharacters(in: .whitespacesAndNewlines)
        if textIsEditable {
            settings.command = try ContainerInput.arguments(from: commandLine)
            settings.environment = try ContainerInput.environment(from: environmentText)
        }
        var machine = config
        machine.container = settings
        try machine.validate()
        return machine
    }
}

extension VMConfig {
    /// A configuration check's reason, without the framework's generic wording around it.
    static func reason(for error: any Error) -> String {
        if case DecodingError.dataCorrupted(let context) = error { return context.debugDescription }
        return error.localizedDescription
    }
}
