import Foundation

/// Why the text typed for a container's settings cannot be used.
struct ContainerInputError: LocalizedError, Equatable {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

/// Turns the text fields of a container's settings into the values a `ContainerSpec` holds.
enum ContainerInput {
    /// Splits one line into arguments, run without a shell. Spaces and tabs separate arguments; a pair of double quotes keeps
    /// what is between them in one argument (`""` is an empty argument, and `a"b c"d` is the single argument `ab cd`).
    /// A backslash is an ordinary character, so a double quote cannot be part of an argument. A quote that is never closed
    /// is refused rather than guessed at.
    static func arguments(from line: String) throws -> [String] {
        var arguments: [String] = []
        var current = ""
        var inArgument = false
        var quoted = false
        for character in line {
            if character == "\"" {
                quoted.toggle()
                inArgument = true
            } else if !quoted && character.isWhitespace {
                if inArgument { arguments.append(current) }
                current = ""
                inArgument = false
            } else {
                current.append(character)
                inArgument = true
            }
        }
        guard !quoted else { throw ContainerInputError("The command has a double quote that is never closed.") }
        if inArgument { arguments.append(current) }
        return arguments
    }

    /// Writes arguments as one line that `arguments(from:)` reads back: an empty argument, or one with whitespace, is put in
    /// double quotes. An argument that holds a double quote cannot be written (the line has no way to keep one), so the line
    /// then reads back as something else; `ContainerDraft` checks for that.
    static func line(from arguments: [String]) -> String {
        arguments.map { argument in
            argument.isEmpty || argument.contains(where: \.isWhitespace) ? "\"\(argument)\"" : argument
        }.joined(separator: " ")
    }

    /// Writes the settings one `NAME=value` per line, in their order.
    static func text(from environment: [ContainerEnvironmentEntry]) -> String {
        environment.map { "\($0.name)=\($0.value)" }.joined(separator: "\n")
    }

    /// Reads one `NAME=value` setting per line, in the order written. Blank lines are skipped, and the value is everything
    /// after the first `=`. Whether a name or a value is acceptable is for `VMConfig.validate()` to say.
    static func environment(from text: String) throws -> [ContainerEnvironmentEntry] {
        try text.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.allSatisfy(\.isWhitespace) else { return nil }
            guard let equals = line.firstIndex(of: "=") else {
                throw ContainerInputError("“\(line)” is not a setting. Write each one as NAME=value.")
            }
            return ContainerEnvironmentEntry(name: String(line[..<equals]), value: String(line[line.index(after: equals)...]))
        }
    }
}
