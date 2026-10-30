import AppKit

enum TextInserter {
    /// Puts the text on the clipboard without pasting.
    static func copyOnly(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func insert(_ text: String) {
        let pasteboard = NSPasteboard.general
        let oldItems = pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
            typeUnicode(text)
            restore(oldItems, to: pasteboard)
            return
        }
        down.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.flags = .maskCommand
        up.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            restore(oldItems, to: pasteboard)
        }
    }

    private static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    private static func typeUnicode(_ string: String) {
        let units = Array(string.utf16)
        for start in stride(from: 0, to: units.count, by: 20) {
            let chunk = Array(units[start..<min(start + 20, units.count)])
            var values = chunk
            let event = values.withUnsafeMutableBufferPointer { buffer -> CGEvent? in
                guard let base = buffer.baseAddress, let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { return nil }
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                return event
            }
            event?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }
}
