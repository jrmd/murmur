import Carbon.HIToolbox

/// Resolves the virtual key code that types a character on the current keyboard layout, so ⌘V pastes on
/// non-QWERTY layouts too instead of posting QWERTY's hard-coded 9.
enum PasteKeyCode {
    /// QWERTY's "v"; used when the layout cannot be read.
    static let fallback: CGKeyCode = 9
    /// "v" as a UTF-16 unit.
    private static let v: UniChar = 0x76

    /// Looks the key up on every call: layouts change while Murmur runs and the lookup is cheap.
    static func current() -> CGKeyCode {
        guard let layout = currentLayout() else { return fallback }
        return keyCode(for: v, in: layout.data, keyboardType: layout.keyboardType) ?? fallback
    }

    /// Scans key codes 0..<128 for the one that types `character` with no modifiers applied.
    static func keyCode(for character: UniChar, in layout: Data, keyboardType: UInt32) -> CGKeyCode? {
        layout.withUnsafeBytes { buffer -> CGKeyCode? in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(base, UInt16(code), UInt16(kUCKeyActionDown), 0, keyboardType,
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                                            characters.count, &length, &characters)
                if status == noErr, length == 1, characters[0] == character { return CGKeyCode(code) }
            }
            return nil
        }
    }

    private static func currentLayout() -> (data: Data, keyboardType: UInt32)? {
        let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
            ?? TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        guard let source, let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return (data, UInt32(LMGetKbdType()))
    }
}
