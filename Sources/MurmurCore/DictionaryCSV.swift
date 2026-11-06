import Foundation

/// CSV import/export for the dictionary: `heard,replacement,match_case,enabled`.
public extension DictionaryStore {
    func csvString() -> String {
        var lines = ["heard,replacement,match_case,enabled"]
        for e in Self.persistable(entries) { lines.append([Self.field(e.heard), Self.field(e.replacement), e.caseSensitive ? "true" : "false", e.enabled ? "true" : "false"].joined(separator: ",")) }
        return lines.joined(separator: "\n") + "\n"
    }

    func exportCSV(to url: URL) throws { try csvString().write(to: url, atomically: true, encoding: .utf8) }

    /// Adds new words and updates existing ones (matched on the heard text, ignoring case). Returns how many rows were applied.
    @discardableResult
    func importCSV(from url: URL) throws -> Int {
        let rows = Self.parse(try String(contentsOf: url, encoding: .utf8))
        var applied = 0
        batching {
            for (index, row) in rows.enumerated() {
                if index == 0, row.first?.lowercased() == "heard" { continue }
                guard row.count >= 2, !row[0].trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let heard = row[0].trimmingCharacters(in: .whitespaces), replacement = row[1].trimmingCharacters(in: .whitespaces)
                let match = row.count > 2 ? Self.truthy(row[2], default: false) : false
                let on = row.count > 3 ? Self.truthy(row[3], default: true) : true
                if var existing = entries.first(where: { $0.heard.caseInsensitiveCompare(heard) == .orderedSame }) {
                    existing.replacement = replacement; existing.caseSensitive = match; existing.enabled = on; update(existing)
                } else {
                    add(DictionaryEntry(heard: heard, replacement: replacement, caseSensitive: match, enabled: on))
                }
                applied += 1
            }
        }
        return applied
    }

    private static func truthy(_ value: String, default fallback: Bool) -> Bool {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "1", "yes", "y", "on": true
        case "false", "0", "no", "n", "off": false
        default: fallback
        }
    }

    private static func field(_ value: String) -> String {
        value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
    }

    /// Minimal RFC 4180 parser (quoted fields, escaped quotes, CRLF).
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var iterator = text.makeIterator(), pending: Character?
        func next() -> Character? { if let p = pending { pending = nil; return p }; return iterator.next() }
        while let c = next() {
            if quoted {
                if c == "\"" { if let n = next() { if n == "\"" { field.append("\"") } else { quoted = false; pending = n } } else { quoted = false } }
                else { field.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
