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
    @Published public var entries: [DictionaryEntry] { didSet { schedulePersist() } }
    public let fileURL: URL
    @Published public private(set) var persistenceError: String?
    private let writer: DictionaryWriter
    private var readError: String?
    private var writeError: String?
    private var deferringWrites = false
    private static let debounce: TimeInterval = 0.3

    public init(fileURL: URL? = nil) {
        // The dev build (bundle id ending in ".dev") keeps its own dictionary so testing never edits the real one.
        let folder = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "Murmur (dev)" : "Murmur"
        let url = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("\(folder)/dictionary.json")
        self.fileURL = url
        self.writer = DictionaryWriter(url: url)
        if FileManager.default.fileExists(atPath: url.path) {
            do { entries = try JSONDecoder().decode([DictionaryEntry].self, from: Data(contentsOf: url)) }
            catch {
                // Never let a later write land on top of a file we couldn't read: move it aside first.
                entries = []
                readError = Self.quarantine(url).map { "Your dictionary couldn't be read; the original was saved as \($0.lastPathComponent)." }
                    ?? "Your dictionary couldn't be read: \(error.localizedDescription)"
            }
        } else { entries = [] }
        persistenceError = readError
    }

    deinit { _ = writer.flush() }

    public func add(_ entry: DictionaryEntry) { entries.append(entry); flushIfNeeded() }
    public func remove(_ entry: DictionaryEntry) { entries.removeAll { $0.id == entry.id }; flushIfNeeded() }
    public func remove(id: UUID) { entries.removeAll { $0.id == id }; flushIfNeeded() }
    public func update(_ entry: DictionaryEntry) { if let i = entries.firstIndex(where: { $0.id == entry.id }) { entries[i] = entry } }

    /// Replaces the whole dictionary with the JSON file's contents.
    public func `import`(from url: URL) throws {
        entries = try JSONDecoder().decode([DictionaryEntry].self, from: Data(contentsOf: url))
        flush()
    }

    /// Imports a JSON dictionary, either replacing everything or merging on `heard` (ignoring case, like CSV). Returns how many entries were applied.
    @discardableResult
    public func importJSON(from url: URL, replacing: Bool) throws -> Int {
        let incoming = try JSONDecoder().decode([DictionaryEntry].self, from: Data(contentsOf: url))
        if replacing { entries = incoming; flush(); return incoming.count }
        var applied = 0
        batching {
            for entry in incoming {
                guard !entry.heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if var existing = entries.first(where: { $0.heard.caseInsensitiveCompare(entry.heard) == .orderedSame }) {
                    existing.replacement = entry.replacement; existing.caseSensitive = entry.caseSensitive; existing.enabled = entry.enabled
                    update(existing)
                } else {
                    add(entry)
                }
                applied += 1
            }
        }
        return applied
    }

    public func export(to url: URL) throws { try JSONEncoder.pretty.encode(Self.persistable(entries)).write(to: url, options: .atomic) }

    /// Writes any pending change to disk immediately.
    public func flush() {
        let result = writer.flush()
        guard result.wrote else { return }
        writeError = result.error.map { "Your dictionary couldn't be saved: \($0)" }
        refreshError()
    }

    /// Runs `body` with writes coalesced into a single flush at the end.
    func batching(_ body: () throws -> Void) rethrows {
        deferringWrites = true
        defer { deferringWrites = false; flush() }
        try body()
    }

    /// Rows the UI creates while editing (both fields blank) stay in memory but are never written.
    static func persistable(_ entries: [DictionaryEntry]) -> [DictionaryEntry] {
        entries.filter { !($0.heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    }

    private func flushIfNeeded() { if !deferringWrites { flush() } }

    private func refreshError() { persistenceError = writeError ?? readError }

    /// Coalesces keystroke-rate edits into one write per debounce window.
    private func schedulePersist() {
        guard let data = try? JSONEncoder.pretty.encode(Self.persistable(entries)) else {
            writeError = "Your dictionary couldn't be saved: the entries couldn't be encoded."
            refreshError()
            return
        }
        guard writer.stage(data) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    /// Moves an unreadable dictionary aside so the next write can't destroy it.
    private static func quarantine(_ url: URL) -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        var target = url.appendingPathExtension("corrupt-\(stamp)")
        var attempt = 1
        while FileManager.default.fileExists(atPath: target.path) {
            target = url.appendingPathExtension("corrupt-\(stamp)-\(attempt)"); attempt += 1
        }
        do { try FileManager.default.moveItem(at: url, to: target); return target } catch { return nil }
    }
}

/// Holds the newest encoded dictionary and writes it at most once per debounce window.
private final class DictionaryWriter: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var pending: Data?
    private var scheduled = false

    init(url: URL) { self.url = url }

    /// Stores the newest payload. Returns true when the caller must schedule a flush.
    func stage(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pending = data
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    /// Writes the pending payload, if any.
    func flush() -> (wrote: Bool, error: String?) {
        lock.lock()
        let data = pending
        pending = nil
        scheduled = false
        lock.unlock()
        guard let data else { return (false, nil) }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return (true, nil)
        } catch { return (true, error.localizedDescription) }
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
        var matches: [(range: NSRange, replacement: String)] = []
        for (_, entry) in candidates {
            guard let regex = RegexCache.shared.regex(for: entry.heard, caseSensitive: entry.caseSensitive) else { continue }
            for result in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard !overlaps(matches, result.range) else { continue }
                insert((result.range, entry.replacement), into: &matches)
            }
        }
        let output = NSMutableString(string: text)
        for match in matches.reversed() { output.replaceCharacters(in: match.range, with: match.replacement) }
        return output as String
    }

    /// `matches` is sorted by location and never overlaps, so only the neighbours can collide.
    private static func overlaps(_ matches: [(range: NSRange, replacement: String)], _ range: NSRange) -> Bool {
        let index = insertionIndex(matches, range.location)
        if index < matches.count, NSIntersectionRange(matches[index].range, range).length > 0 { return true }
        if index > 0, NSIntersectionRange(matches[index - 1].range, range).length > 0 { return true }
        return false
    }

    private static func insert(_ match: (range: NSRange, replacement: String), into matches: inout [(range: NSRange, replacement: String)]) {
        matches.insert(match, at: insertionIndex(matches, match.range.location))
    }

    private static func insertionIndex(_ matches: [(range: NSRange, replacement: String)], _ location: Int) -> Int {
        var low = 0, high = matches.count
        while low < high {
            let mid = (low + high) / 2
            if matches[mid].range.location < location { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// Compiled patterns keyed by (heard, caseSensitive). Bounded: a full dictionary swap just drops the cache.
private final class RegexCache: @unchecked Sendable {
    static let shared = RegexCache()
    private let lock = NSLock()
    private var storage: [String: NSRegularExpression] = [:]
    private let limit = 256

    func regex(for heard: String, caseSensitive: Bool) -> NSRegularExpression? {
        let key = "\(caseSensitive ? 1 : 0)\u{1}\(heard)"
        lock.lock()
        if let cached = storage[key] { lock.unlock(); return cached }
        lock.unlock()
        let escaped = NSRegularExpression.escapedPattern(for: heard)
        // Only forbids adjacent word characters, so "C++" and ".NET" still match at their edges.
        let pattern = "(?<![\\p{L}\\p{M}\\p{N}_])" + escaped + "(?![\\p{L}\\p{M}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else { return nil }
        lock.lock()
        if storage.count >= limit { storage.removeAll(keepingCapacity: true) }
        storage[key] = regex
        lock.unlock()
        return regex
    }
}
