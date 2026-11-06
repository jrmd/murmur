import AppKit
import ApplicationServices

enum TextInserter {
    /// How long the dictation stays on the clipboard before the old contents come back. Long enough for slow apps
    /// to read the paste, short enough that the clipboard is not noticeably hijacked.
    private static let restoreDelay: TimeInterval = 1.0
    /// Unicode key events carry at most this many UTF-16 units.
    private static let maxUnitsPerEvent = 20

    /// Puts the text on the clipboard without pasting. The user asked for it, so it carries no transient markers.
    static func copyOnly(_ text: String) {
        NSPasteboard.general.writeDictation(text, concealed: false)
    }

    /// Pastes the text into the frontmost app. Returns false only when no route managed to post anything.
    @discardableResult
    static func insert(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard)
        let changeCount = pasteboard.writeDictation(text, concealed: true)
        if postPaste() {
            // Restore only if the clipboard still holds the dictation, so anything the user copied meanwhile survives.
            DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
                guard pasteboard.changeCount == changeCount else { return }
                snapshot.restore(to: pasteboard)
            }
            return true
        }
        snapshot.restore(to: pasteboard)
        if insertViaAccessibility(text) { return true }
        return typeUnicode(text)
    }

    /// Posts ⌘V with the key code the current layout uses for "v".
    private static func postPaste() -> Bool {
        let key = PasteKeyCode.current()
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Fallback for apps that ignore synthetic ⌘V: hand the text to the focused element as its selection.
    private static func insertViaAccessibility(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }

    /// Types the text as unicode key events, chunked so no surrogate pair or grapheme cluster is split.
    private static func typeUnicode(_ text: String) -> Bool {
        var chunk: [UniChar] = []
        var posted = false
        func flush() {
            guard !chunk.isEmpty else { return }
            posted = postUnicode(chunk) || posted
            chunk = []
        }
        for character in text {
            let units = Array(String(character).utf16)
            // A single grapheme can be longer than one event; fall back to its scalars so no pair is split.
            let pieces = units.count > maxUnitsPerEvent ? character.unicodeScalars.map { Array(String(Character($0)).utf16) } : [units]
            for piece in pieces {
                if chunk.count + piece.count > maxUnitsPerEvent { flush() }
                chunk.append(contentsOf: piece)
            }
        }
        flush()
        return posted
    }

    private static func postUnicode(_ units: [UniChar]) -> Bool {
        var values = units
        let down = values.withUnsafeMutableBufferPointer { buffer -> CGEvent? in
            guard let base = buffer.baseAddress, let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { return nil }
            event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            return event
        }
        guard let down else { return false }
        down.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)?.post(tap: .cghidEventTap)
        return true
    }
}
