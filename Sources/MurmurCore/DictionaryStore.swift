import Foundation
import Combine

public struct DictionaryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var heard: String
    public var replacement: String
    public var caseSensitive: Bool
    public var enabled: Bool
    public init(id: UUID = UUID(), heard: String, replacement: String, caseSensitive: Bool = false, enabled: Bool = true) {
        self.id = id; self.heard = heard; self.replacement = replacement; self.caseSensitive = caseSensitive; self.enabled = enabled
    }
    private enum CodingKeys: String, CodingKey { case id, heard, replacement, caseSensitive, enabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        heard = try c.decode(String.self, forKey: .heard); replacement = try c.decode(String.self, forKey: .replacement)
        caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

@MainActor public final class DictionaryStore: ObservableObject {
    @Published public var entries: [DictionaryEntry] { didSet { persist() } }
    public let fileURL: URL
    @Published public private(set) var persistenceError: String?
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Murmur/dictionary.json")
        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            do { entries = try JSONDecoder().decode([DictionaryEntry].self, from: Data(contentsOf: self.fileURL)) }
            catch { entries = []; persistenceError = error.localizedDescription }
        } else { entries = [] }
    }
    public func add(_ entry: DictionaryEntry) { entries.append(entry) }
    public func remove(_ entry: DictionaryEntry) { entries.removeAll { $0.id == entry.id } }
    public func remove(id: UUID) { entries.removeAll { $0.id == id } }
    public func update(_ entry: DictionaryEntry) { if let i = entries.firstIndex(where: { $0.id == entry.id }) { entries[i] = entry } }
    public func `import`(from url: URL) throws { entries = try JSONDecoder().decode([DictionaryEntry].self, from: Data(contentsOf: url)) }
    public func export(to url: URL) throws { try JSONEncoder.pretty.encode(entries).write(to: url, options: .atomic) }
    private func persist() {
        do { try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder.pretty.encode(entries).write(to: fileURL, options: .atomic); persistenceError = nil }
        catch { persistenceError = error.localizedDescription }
    }
}
private extension JSONEncoder { static var pretty: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e } }

public enum DictionaryReplacer {
    /// Matches against the original input once, so replacements never cascade.
    public static func apply(_ text: String, entries: [DictionaryEntry]) -> String {
        let candidates = entries.enumerated().filter { $0.element.enabled && !$0.element.heard.isEmpty }.sorted {
            let a = $0.element.heard.utf16.count, b = $1.element.heard.utf16.count
            return a == b ? $0.offset < $1.offset : a > b
        }
        let ns = text as NSString
        var matches: [(NSRange, String)] = []
        for (_, entry) in candidates {
            let escaped = NSRegularExpression.escapedPattern(for: entry.heard)
            let pattern = "(?<![\\p{L}\\p{M}\\p{N}_])" + escaped + "(?![\\p{L}\\p{M}\\p{N}_])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: entry.caseSensitive ? [] : [.caseInsensitive]) else { continue }
            for result in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if !matches.contains(where: { NSIntersectionRange($0.0, result.range).length > 0 }) { matches.append((result.range, entry.replacement)) }
            }
        }
        let output = NSMutableString(string: text)
        for (range, replacement) in matches.sorted(by: { $0.0.location > $1.0.location }) { output.replaceCharacters(in: range, with: replacement) }
        return output as String
    }
}
