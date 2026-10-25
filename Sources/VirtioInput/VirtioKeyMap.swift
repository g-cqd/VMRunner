/// The keys of a Mac keyboard as the Linux input subsystem names them, for the guest's virtio keyboard. The Mac side is the
/// virtual key code of `NSEvent.keyCode` (`kVK_*` in the system's `Events.h`); the app passes the number, so this file imports
/// nothing. The Linux side is the `KEY_*` code of `input-event-codes.h`. The table covers the ANSI layout, the ISO section key
/// (`KEY_102ND`), the modifiers, the function keys up to F20, the keypad, the navigation keys, the volume keys, the help key
/// (`KEY_INSERT`) and the context menu key (`KEY_COMPOSE`). The JIS keys (`kVK_JIS_*`) and every code that is not a key are
/// unmapped.
package enum VirtioKeyMap {  // @dw:accept:this referenced-only-by-tests -- the app links it later
    /// The Linux key for a Mac virtual key code, or `nil` for a code the table does not map.
    package static func linuxKey(forMacKeyCode code: UInt16) -> UInt16? {
        table[code]
    }

    /// Every Linux key the table produces, once each and in increasing order: the keys the keyboard layout advertises.
    package static let linuxKeys: [UInt16] = table.values.sorted()

    private static let table: [UInt16: UInt16] = [
        0x00: 30,  // A
        0x01: 31,  // S
        0x02: 32,  // D
        0x03: 33,  // F
        0x04: 35,  // H
        0x05: 34,  // G
        0x06: 44,  // Z
        0x07: 45,  // X
        0x08: 46,  // C
        0x09: 47,  // V
        0x0A: 86,  // ISO_Section
        0x0B: 48,  // B
        0x0C: 16,  // Q
        0x0D: 17,  // W
        0x0E: 18,  // E
        0x0F: 19,  // R
        0x10: 21,  // Y
        0x11: 20,  // T
        0x12: 2,  // 1
        0x13: 3,  // 2
        0x14: 4,  // 3
        0x15: 5,  // 4
        0x16: 7,  // 6
        0x17: 6,  // 5
        0x18: 13,  // Equal
        0x19: 10,  // 9
        0x1A: 8,  // 7
        0x1B: 12,  // Minus
        0x1C: 9,  // 8
        0x1D: 11,  // 0
        0x1E: 27,  // RightBracket
        0x1F: 24,  // O
        0x20: 22,  // U
        0x21: 26,  // LeftBracket
        0x22: 23,  // I
        0x23: 25,  // P
        0x24: 28,  // Return
        0x25: 38,  // L
        0x26: 36,  // J
        0x27: 40,  // Quote
        0x28: 37,  // K
        0x29: 39,  // Semicolon
        0x2A: 43,  // Backslash
        0x2B: 51,  // Comma
        0x2C: 53,  // Slash
        0x2D: 49,  // N
        0x2E: 50,  // M
        0x2F: 52,  // Period
        0x30: 15,  // Tab
        0x31: 57,  // Space
        0x32: 41,  // Grave
        0x33: 14,  // Delete
        0x35: 1,  // Escape
        0x36: 126,  // RightCommand
        0x37: 125,  // Command
        0x38: 42,  // Shift
        0x39: 58,  // CapsLock
        0x3A: 56,  // Option
        0x3B: 29,  // Control
        0x3C: 54,  // RightShift
        0x3D: 100,  // RightOption
        0x3E: 97,  // RightControl
        0x3F: 464,  // Function
        0x40: 187,  // F17
        0x41: 83,  // KeypadDecimal
        0x43: 55,  // KeypadMultiply
        0x45: 78,  // KeypadPlus
        0x47: 69,  // KeypadClear
        0x48: 115,  // VolumeUp
        0x49: 114,  // VolumeDown
        0x4A: 113,  // Mute
        0x4B: 98,  // KeypadDivide
        0x4C: 96,  // KeypadEnter
        0x4E: 74,  // KeypadMinus
        0x4F: 188,  // F18
        0x50: 189,  // F19
        0x51: 117,  // KeypadEquals
        0x52: 82,  // Keypad0
        0x53: 79,  // Keypad1
        0x54: 80,  // Keypad2
        0x55: 81,  // Keypad3
        0x56: 75,  // Keypad4
        0x57: 76,  // Keypad5
        0x58: 77,  // Keypad6
        0x59: 71,  // Keypad7
        0x5A: 190,  // F20
        0x5B: 72,  // Keypad8
        0x5C: 73,  // Keypad9
        0x60: 63,  // F5
        0x61: 64,  // F6
        0x62: 65,  // F7
        0x63: 61,  // F3
        0x64: 66,  // F8
        0x65: 67,  // F9
        0x67: 87,  // F11
        0x69: 183,  // F13
        0x6A: 186,  // F16
        0x6B: 184,  // F14
        0x6D: 68,  // F10
        0x6E: 127,  // ContextualMenu
        0x6F: 88,  // F12
        0x71: 185,  // F15
        0x72: 110,  // Help
        0x73: 102,  // Home
        0x74: 104,  // PageUp
        0x75: 111,  // ForwardDelete
        0x76: 62,  // F4
        0x77: 107,  // End
        0x78: 60,  // F2
        0x79: 109,  // PageDown
        0x7A: 59,  // F1
        0x7B: 105,  // Left
        0x7C: 106,  // Right
        0x7D: 108,  // Down
        0x7E: 103,  // Up
    ]
}
