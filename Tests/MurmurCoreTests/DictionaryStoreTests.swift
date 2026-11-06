import XCTest
@testable import MurmurCore

@MainActor
final class DictionaryStoreTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
        super.tearDown()
    }

    private func makeStore() -> (DictionaryStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-dict-\(UUID())")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        let url = folder.appendingPathComponent("dictionary.json")
        return (DictionaryStore(fileURL: url), url)
    }

    private func persisted(_ url: URL) throws -> [DictionaryEntry] {
        try JSONDecoder().decode([DictionaryEntry].self, from: Data(contentsOf: url))
    }

    private func quarantinedFiles(near url: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        return names.filter { $0.contains(".corrupt-") }.sorted().map { url.deletingLastPathComponent().appendingPathComponent($0) }
    }

    // MARK: Corrupt file

    func testCorruptFileIsMovedAsideBeforeAnyWrite() throws {
        let (store, url) = makeStore()
        try Data("not a dictionary".utf8).write(to: url)

        let reopened = DictionaryStore(fileURL: url)
        XCTAssertTrue(reopened.entries.isEmpty)
        XCTAssertEqual(reopened.persistenceError?.contains("couldn't be read"), true, reopened.persistenceError ?? "nil")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the unreadable file must be moved, not left in place")

        let backups = quarantinedFiles(near: url)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: backups[0], encoding: .utf8), "not a dictionary")
        XCTAssertEqual(reopened.persistenceError?.contains(backups[0].lastPathComponent), true)

        reopened.add(DictionaryEntry(heard: "murmer", replacement: "Murmur"))
        reopened.flush()
        XCTAssertEqual(try persisted(url).map(\.heard), ["murmer"])

        // The next launch reads cleanly instead of failing again.
        let third = DictionaryStore(fileURL: url)
        XCTAssertEqual(third.entries.map(\.heard), ["murmer"])
        XCTAssertNil(third.persistenceError)
        _ = store
    }

    func testCorruptFileKeepsBothBackupsWhenItHappensTwice() throws {
        let (_, url) = makeStore()
        try Data("garbage one".utf8).write(to: url)
        _ = DictionaryStore(fileURL: url)
        try Data("garbage two".utf8).write(to: url)
        _ = DictionaryStore(fileURL: url)
        XCTAssertEqual(quarantinedFiles(near: url).count, 2)
    }

    // MARK: Persistence errors

    func testWriteFailureIsReportedAsAWriteFailure() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-dict-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        let blocker = folder.appendingPathComponent("blocker")
        try Data("not a folder".utf8).write(to: blocker)

        let store = DictionaryStore(fileURL: blocker.appendingPathComponent("dictionary.json"))
        XCTAssertNil(store.persistenceError)
        store.add(DictionaryEntry(heard: "a", replacement: "b"))
        store.flush()
        XCTAssertEqual(store.persistenceError?.contains("couldn't be saved"), true, store.persistenceError ?? "nil")
        XCTAssertEqual(store.persistenceError?.contains("couldn't be read"), false)
    }

    func testReadErrorSurvivesALaterSuccessfulWrite() throws {
        let (_, url) = makeStore()
        try Data("garbage".utf8).write(to: url)
        let store = DictionaryStore(fileURL: url)
        store.add(DictionaryEntry(heard: "a", replacement: "b"))
        store.flush()
        XCTAssertEqual(store.persistenceError?.contains("couldn't be read"), true, "the quarantine notice should not be wiped by a write")
    }

    // MARK: Debounce and flush

    func testEditsAreDebouncedUntilFlush() throws {
        let (store, url) = makeStore()
        store.add(DictionaryEntry(heard: "a", replacement: "b"))
        XCTAssertEqual(try persisted(url).map(\.replacement), ["b"], "add should flush promptly")

        var entry = store.entries[0]
        entry.replacement = "c"
        store.update(entry)
        XCTAssertEqual(try persisted(url).map(\.replacement), ["b"], "a keystroke edit should not hit the disk immediately")

        store.flush()
        XCTAssertEqual(try persisted(url).map(\.replacement), ["c"])
    }

    func testRemoveFlushesPromptly() throws {
        let (store, url) = makeStore()
        let entry = DictionaryEntry(heard: "a", replacement: "b")
        store.add(entry)
        store.remove(entry)
        XCTAssertTrue(try persisted(url).isEmpty)
    }

    func testDeinitFlushesPendingEdits() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-dict-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        let url = folder.appendingPathComponent("dictionary.json")

        editAndDropStore(at: url)
        XCTAssertEqual(try persisted(url).map(\.replacement), ["pending"], "deinit must flush the pending write")
    }

    /// Creates a store, makes a debounced edit, then lets it deallocate.
    private func editAndDropStore(at url: URL) {
        let store = DictionaryStore(fileURL: url)
        store.add(DictionaryEntry(heard: "a", replacement: "b"))
        var entry = store.entries[0]
        entry.replacement = "pending"
        store.update(entry)
        XCTAssertEqual(try? persisted(url).map(\.replacement), ["b"], "the edit should still be pending")
    }

    // MARK: Blank rows

    func testBlankRowsStayInMemoryButAreNeverWritten() throws {
        let (store, url) = makeStore()
        store.add(DictionaryEntry(heard: "  ", replacement: ""))
        store.flush()
        XCTAssertEqual(store.entries.count, 1, "the row the UI is editing must stay in memory")
        XCTAssertTrue(try persisted(url).isEmpty)

        store.add(DictionaryEntry(heard: "", replacement: "Murmur"))
        store.flush()
        XCTAssertEqual(try persisted(url).map(\.replacement), ["Murmur"], "only rows with both fields blank are dropped")
    }

    func testBlankRowsAreLeftOutOfExports() throws {
        let (store, _) = makeStore()
        store.add(DictionaryEntry(heard: "", replacement: ""))
        store.add(DictionaryEntry(heard: "a", replacement: "b"))
        XCTAssertEqual(store.csvString().split(separator: "\n").count, 2)
        let json = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-export-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: json) }
        try store.export(to: json)
        XCTAssertEqual(try persisted(json).map(\.heard), ["a"])
    }

    // MARK: JSON import

    func testImportJSONMergesOnHeardIgnoringCase() throws {
        let (store, _) = makeStore()
        store.add(DictionaryEntry(heard: "Hello", replacement: "hi"))
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-import-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: source) }
        try JSONEncoder().encode([
            DictionaryEntry(heard: "hello", replacement: "HI", caseSensitive: true, enabled: false),
            DictionaryEntry(heard: "new", replacement: "N"),
            DictionaryEntry(heard: "   ", replacement: "ignored")
        ]).write(to: source)

        XCTAssertEqual(try store.importJSON(from: source, replacing: false), 2)
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries[0].replacement, "HI")
        XCTAssertTrue(store.entries[0].caseSensitive)
        XCTAssertFalse(store.entries[0].enabled)
        XCTAssertEqual(store.entries[1].heard, "new")
    }

    func testImportJSONReplacingSwapsEverything() throws {
        let (store, url) = makeStore()
        store.add(DictionaryEntry(heard: "old", replacement: "x"))
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-import-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: source) }
        try JSONEncoder().encode([DictionaryEntry(heard: "only", replacement: "y")]).write(to: source)

        XCTAssertEqual(try store.importJSON(from: source, replacing: true), 1)
        XCTAssertEqual(store.entries.map(\.heard), ["only"])
        XCTAssertEqual(try persisted(url).map(\.heard), ["only"], "replacing import should flush")
    }

    func testLegacyImportStillReplaces() throws {
        let (store, _) = makeStore()
        store.add(DictionaryEntry(heard: "old", replacement: "x"))
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-import-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: source) }
        try JSONEncoder().encode([DictionaryEntry(heard: "only", replacement: "y")]).write(to: source)
        try store.import(from: source)
        XCTAssertEqual(store.entries.map(\.heard), ["only"])
    }

    // MARK: Replacer

    func testNonWordEdgesMatch() {
        let entries = [DictionaryEntry(heard: "C++", replacement: "cpp"), DictionaryEntry(heard: ".NET", replacement: "dotnet")]
        XCTAssertEqual(DictionaryReplacer.apply("I like C++ and .NET 8", entries: entries), "I like cpp and dotnet 8")
        XCTAssertEqual(DictionaryReplacer.apply("C++x and a.NET", entries: entries), "C++x and a.NET", "adjacent word characters still block a match")
        XCTAssertEqual(DictionaryReplacer.apply("(C++)", entries: entries), "(cpp)")
    }

    func testReplacementStringsAreLiteral() {
        let entries = [DictionaryEntry(heard: "price", replacement: "$1 \\0 $&"), DictionaryEntry(heard: "path", replacement: "C:\\temp")]
        XCTAssertEqual(DictionaryReplacer.apply("price path", entries: entries), "$1 \\0 $& C:\\temp")
    }

    func testCacheKeepsCaseOptionsApart() {
        let sensitive = [DictionaryEntry(heard: "cat", replacement: "X", caseSensitive: true)]
        let loose = [DictionaryEntry(heard: "cat", replacement: "Y")]
        XCTAssertEqual(DictionaryReplacer.apply("Cat cat", entries: sensitive), "Cat X")
        XCTAssertEqual(DictionaryReplacer.apply("Cat cat", entries: loose), "Y Y")
        XCTAssertEqual(DictionaryReplacer.apply("Cat cat", entries: sensitive), "Cat X")
    }

    func testManyMatchesAreAllReplaced() {
        let text = Array(repeating: "new", count: 50).joined(separator: " ")
        let entries = [DictionaryEntry(heard: "new", replacement: "old"), DictionaryEntry(heard: "new new", replacement: "pair")]
        let output = DictionaryReplacer.apply(text, entries: entries)
        XCTAssertEqual(output, Array(repeating: "pair", count: 25).joined(separator: " "))
    }

    func testLongestWinsAndTiesKeepEntryOrder() {
        let entries = [DictionaryEntry(heard: "a b", replacement: "first"), DictionaryEntry(heard: "a b", replacement: "second")]
        XCTAssertEqual(DictionaryReplacer.apply("a b", entries: entries), "first")
        XCTAssertEqual(DictionaryReplacer.apply("a b c", entries: [DictionaryEntry(heard: "a", replacement: "1"), DictionaryEntry(heard: "a b", replacement: "2")]), "2 c")
    }
}
