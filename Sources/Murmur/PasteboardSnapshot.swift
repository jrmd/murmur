import AppKit

extension NSPasteboard.PasteboardType {
    /// Standard markers clipboard managers honour: the item is transient and private, so it is not recorded.
    static let transientMarker = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealedMarker = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
}

extension NSPasteboard {
    /// Replaces the contents with a single item holding `text`, optionally marked transient and concealed so
    /// clipboard managers skip it. Returns the change count to compare against before restoring.
    @discardableResult
    func writeDictation(_ text: String, concealed: Bool) -> Int {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if concealed {
            item.setData(Data(), forType: .transientMarker)
            item.setData(Data(), forType: .concealedMarker)
        }
        clearContents()
        writeObjects([item])
        return changeCount
    }
}

/// A copy of the pasteboard's items, keeping every type (text, file URLs, images) so it can be put back after a paste.
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard = .general) {
        items = pasteboard.pasteboardItems?.map { item in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { contents[type] = item.data(forType: type) }
            return contents
        } ?? []
    }

    /// Puts the snapshot back. An empty snapshot leaves the pasteboard cleared, as it was.
    func restore(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items.map { contents in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        })
    }
}
