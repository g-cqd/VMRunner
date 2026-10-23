/// Makes what a guest prints safe to show on a person's terminal.
///
/// A guest is untrusted, and a terminal acts on what it is sent: a guest could set the window title, write or read the
/// clipboard, make the terminal type answers to queries into the person's input, switch on modes that outlive the session
/// (the alternate screen, mouse reporting, bracketed paste, keyboard protocols) or reset the terminal. The filter passes text
/// and a short allow-list, and removes everything else whole: a removed sequence leaves no character behind.
///
/// What passes: printable ASCII; well-formed UTF-8 (a malformed or cut-short character is dropped); line feed, carriage
/// return, tab, backspace and the bell; and CSI sequences with no private marker and no intermediate byte that set colours
/// and attributes (SGR, `m`), move the cursor (`A` `B` `C` `D` `G` `H` `f`), erase in the line (`K`) or the display (`J`,
/// parameters 0 to 2: never the scrollback), or insert, delete or erase characters (`@` `P` `X`). That is what a boot log, a
/// login prompt and a shell's line editing use.
///
/// What is removed: every other control byte (C0, DEL, and C1 as a single byte or in its UTF-8 form; a C1 control in UTF-8
/// form that opens a sequence takes the sequence with it), every other escape sequence, and every control string (OSC,
/// DCS, SOS, PM, APC). The filter assumes a terminal that reads UTF-8: in a legacy 8-bit mode, bytes 0x80 to 0x9F inside a
/// UTF-8 character would be read as C1 controls, which a filter that passes UTF-8 cannot prevent.
///
/// The state carries over from one call to the next, so a sequence or a character cut between two reads is handled, and it
/// is bounded: a CSI sequence longer than ``sequenceLimit`` bytes is dropped whole, and a control string still open after
/// ``stringLimit`` bytes is given up, after which bytes read as text again.
public struct ConsoleOutputFilter: Sendable {
    /// The longest CSI sequence kept, ESC and `[` included; a longer one is dropped whole.
    public static let sequenceLimit = 256
    /// How many bytes of a control string are skipped before the filter stops waiting for its end and reads text again.
    public static let stringLimit = 4 * 1024

    private enum State: Sendable {
        /// Text.
        case ground
        /// After ESC.
        case escape
        /// After ESC and an intermediate byte (0x20 to 0x2F), as in a character set designation.
        case escapeIntermediate
        /// Inside a CSI sequence (ESC `[`).
        case sequence
        /// Inside a control string (OSC, DCS, SOS, PM, APC).
        case string
        /// After ESC inside a control string, where `\` ends the string.
        case stringEscape
    }

    /// The controls that pass in text: bell, backspace, tab, line feed and carriage return.
    private static let passedControls: Set<UInt8> = [0x07, 0x08, 0x09, 0x0A, 0x0D]
    /// The final bytes of the cursor and character sequences that pass.
    private static let movements: Set<UInt8> = Set("ABCDGHf@PX".utf8)

    private var state = State.ground
    /// The CSI sequence read so far, ESC and `[` included.
    private var held: [UInt8] = []
    /// Whether the CSI sequence being read is dropped whatever its end (too long, or opened by a C1 control).
    private var dropsSequence = false
    /// How many bytes of the current control string were skipped.
    private var skipped = 0
    /// The first bytes of a UTF-8 character whose end has not arrived.
    private var partial: [UInt8] = []
    /// How many more bytes `partial` needs.
    private var missing = 0

    public init() {}

    /// What of `bytes` may reach the terminal, given everything this filter was passed before.
    public mutating func pass(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        for byte in bytes { step(byte, into: &output) }
        return output
    }

    private mutating func step(_ byte: UInt8, into output: inout [UInt8]) {
        switch state {
        case .ground: text(byte, into: &output)
        case .escape: escape(byte, into: &output)
        case .escapeIntermediate: escapeIntermediate(byte, into: &output)
        case .sequence: sequence(byte, into: &output)
        case .string: string(byte)
        case .stringEscape: stringEscape(byte, into: &output)
        }
    }

    // MARK: Text

    private mutating func text(_ byte: UInt8, into output: inout [UInt8]) {
        if missing > 0 {
            continueCharacter(byte, into: &output)
            return
        }
        switch byte {
        case 0x1B: state = .escape
        case 0x20...0x7E: output.append(byte)
        case 0x00...0x1F, 0x7F: Self.control(byte, into: &output)
        case 0xC2...0xDF: startCharacter(byte, needing: 1)
        case 0xE0...0xEF: startCharacter(byte, needing: 2)
        case 0xF0...0xF4: startCharacter(byte, needing: 3)
        default: break  // 0x80 to 0xC1 and 0xF5 to 0xFF start no character; a single C1 byte is dropped alone
        }
    }

    private static func control(_ byte: UInt8, into output: inout [UInt8]) {
        if passedControls.contains(byte) { output.append(byte) }
    }

    private mutating func startCharacter(_ byte: UInt8, needing count: Int) {
        partial.removeAll(keepingCapacity: true)
        partial.append(byte)
        missing = count
    }

    private mutating func continueCharacter(_ byte: UInt8, into output: inout [UInt8]) {
        guard Self.continues(partial, with: byte) else {
            // The character was cut short: it is dropped, and the byte that cut it is read on its own.
            missing = 0
            text(byte, into: &output)
            return
        }
        partial.append(byte)
        missing -= 1
        guard missing == 0 else { return }
        if partial.count == 2, partial[0] == 0xC2, partial[1] < 0xA0 {
            dropC1(partial[1])  // U+0080 to U+009F: a C1 control in its UTF-8 form
        } else {
            output.append(contentsOf: partial)
        }
    }

    /// Whether `byte` may follow `partial` in a well-formed UTF-8 character (the Unicode standard's table 3-7: no overlong
    /// form, no surrogate, nothing above U+10FFFF).
    private static func continues(_ partial: [UInt8], with byte: UInt8) -> Bool {
        guard partial.count == 1 else { return (0x80...0xBF).contains(byte) }
        switch partial[0] {
        case 0xE0: return (0xA0...0xBF).contains(byte)
        case 0xED: return (0x80...0x9F).contains(byte)
        case 0xF0: return (0x90...0xBF).contains(byte)
        case 0xF4: return (0x80...0x8F).contains(byte)
        default: return (0x80...0xBF).contains(byte)
        }
    }

    /// A C1 control in UTF-8 form is dropped; one that opens a CSI sequence or a control string (DCS, SOS, OSC, PM, APC)
    /// takes it along, so what follows does not show as text.
    private mutating func dropC1(_ code: UInt8) {
        switch code {
        case 0x9B: startSequence(dropped: true)
        case 0x90, 0x98, 0x9D, 0x9E, 0x9F: startString()
        default: break
        }
    }

    // MARK: Escape sequences

    private mutating func escape(_ byte: UInt8, into output: inout [UInt8]) {
        switch byte {
        case 0x5B: startSequence(dropped: false)
        case 0x50, 0x58, 0x5D, 0x5E, 0x5F: startString()  // P X ] ^ _: DCS, SOS, OSC, PM, APC
        case 0x20...0x2F: state = .escapeIntermediate
        case 0x30...0x7E: state = .ground  // a two-byte escape (a reset, a keypad mode, saving the cursor...): dropped
        default: interrupt(byte, into: &output)
        }
    }

    private mutating func escapeIntermediate(_ byte: UInt8, into output: inout [UInt8]) {
        switch byte {
        case 0x20...0x2F: break
        case 0x30...0x7E: state = .ground  // a character set designation or the like: dropped
        default: interrupt(byte, into: &output)
        }
    }

    private mutating func startSequence(dropped: Bool) {
        state = .sequence
        held.removeAll(keepingCapacity: true)
        held.append(contentsOf: [0x1B, 0x5B])
        dropsSequence = dropped
    }

    private mutating func sequence(_ byte: UInt8, into output: inout [UInt8]) {
        switch byte {
        case 0x20...0x3F:
            hold(byte)
        case 0x40...0x7E:
            hold(byte)
            state = .ground
            if !dropsSequence, Self.allows(held) { output.append(contentsOf: held) }
        default:
            interrupt(byte, into: &output)
        }
    }

    private mutating func hold(_ byte: UInt8) {
        if held.count < Self.sequenceLimit {
            held.append(byte)
        } else {
            dropsSequence = true
        }
    }

    /// A byte outside a sequence's grammar, met inside the sequence, acts as it does on a terminal: ESC opens a new
    /// sequence, CAN and SUB cancel this one, the controls that pass in text pass and the other controls are dropped (the
    /// sequence goes on), and a byte from 0x80 up ends the sequence and is read as text.
    private mutating func interrupt(_ byte: UInt8, into output: inout [UInt8]) {
        switch byte {
        case 0x1B: state = .escape
        case 0x18, 0x1A: state = .ground
        case 0x00...0x1F, 0x7F: Self.control(byte, into: &output)
        default:
            state = .ground
            text(byte, into: &output)
        }
    }

    /// Whether a whole CSI sequence (ESC, `[`, its parameters and its final byte) may reach the terminal. A private marker
    /// (`<` `=` `>` `?`) or an intermediate byte makes a sequence a mode, a query or a report, so only digits and `;` are
    /// accepted as parameters, and `:` in SGR for colour sub-parameters.
    static func allows(_ sequence: [UInt8]) -> Bool {
        guard sequence.count >= 3, let kind = sequence.last else { return false }
        let parameters = sequence[2..<(sequence.count - 1)]
        if kind == UInt8(ascii: "m") { return parameters.allSatisfy { (0x30...0x3B).contains($0) } }
        if kind == UInt8(ascii: "J") || kind == UInt8(ascii: "K") {
            return parameters.isEmpty || (parameters.count == 1 && parameters.allSatisfy { (0x30...0x32).contains($0) })
        }
        return movements.contains(kind) && parameters.allSatisfy { (0x30...0x39).contains($0) || $0 == 0x3B }
    }

    // MARK: Control strings

    private mutating func startString() {
        state = .string
        skipped = 0
    }

    private mutating func string(_ byte: UInt8) {
        switch byte {
        case 0x07, 0x18, 0x1A: state = .ground  // the bell ends an OSC, as terminals accept; CAN and SUB cancel the string
        case 0x1B: state = .stringEscape
        default:
            skipped += 1
            if skipped >= Self.stringLimit { state = .ground }
        }
    }

    private mutating func stringEscape(_ byte: UInt8, into output: inout [UInt8]) {
        if byte == 0x5C {
            state = .ground  // ESC \ is the string terminator
        } else {
            state = .escape
            escape(byte, into: &output)
        }
    }
}
