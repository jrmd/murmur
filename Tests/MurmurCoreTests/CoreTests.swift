import XCTest
@testable import MurmurCore
final class CoreTests: XCTestCase {
    func testLongestBoundariesAndNoCascading() {
        let entries = [DictionaryEntry(heard: "new", replacement: "old"), DictionaryEntry(heard: "new york", replacement: "NYC"), DictionaryEntry(heard: "NYC", replacement: "wrong")]
        XCTAssertEqual(DictionaryReplacer.apply("New York, new! newer NYC", entries: entries), "NYC, old! newer wrong")
    }
    func testCaseAndDisabledAndUnicodeBoundaries() {
        let entries = [DictionaryEntry(heard: "cat", replacement: "dog", caseSensitive: true), DictionaryEntry(heard: "fox", replacement: "wolf", enabled: false)]
        XCTAssertEqual(DictionaryReplacer.apply("Cat cat caté fox", entries: entries), "Cat dog caté fox")
    }
    func testPromptIncludesTextAndEnabledHints() {
        let prompt = TidyPrompt.make(text: "um \"hi\"", dictionary: [DictionaryEntry(heard: "x", replacement: "Murmur"), DictionaryEntry(heard: "y", replacement: "secret", enabled: false)])
        XCTAssertTrue(prompt.contains("Murmur")); XCTAssertFalse(prompt.contains("secret")); XCTAssertTrue(prompt.contains("um \"hi\"")); XCTAssertTrue(prompt.contains("do not summarise"))
    }
    @MainActor func testCSVRoundTripKeepsQuotesCommasAndFlags() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-dict-\(UUID()).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("murmur-store-\(UUID()).json"))
        store.add(DictionaryEntry(heard: "buddy and lola", replacement: "Buddy, \"B\" & Lola", caseSensitive: true, enabled: false))
        store.add(DictionaryEntry(heard: "g p u i", replacement: "GPUI"))
        try store.exportCSV(to: url)
        let other = DictionaryStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("murmur-store-\(UUID()).json"))
        XCTAssertEqual(try other.importCSV(from: url), 2)
        XCTAssertEqual(other.entries.map(\.replacement), ["Buddy, \"B\" & Lola", "GPUI"])
        XCTAssertEqual(other.entries.map(\.caseSensitive), [true, false])
        XCTAssertEqual(other.entries.map(\.enabled), [false, true])
    }
    func testCleanupLevelsChangeThePrompt() {
        let light = TidyPrompt.system(dictionary: [], level: .light), strict = TidyPrompt.system(dictionary: [], level: .strict)
        XCTAssertNotEqual(light, strict)
        XCTAssertTrue(light.contains("Keep every word"))
        XCTAssertTrue(strict.contains("repeated"))
    }
    func testMurmurCleanUsesTrainedPromptWithVocabulary() {
        let entries = [DictionaryEntry(heard: "murmer", replacement: "Murmur"), DictionaryEntry(heard: "g g u f", replacement: "GGUF"), DictionaryEntry(heard: "x", replacement: "Hidden", enabled: false)]
        let system = TidyPrompt.murmurCleanSystem(dictionary: entries)
        XCTAssertTrue(system.hasPrefix("You clean up raw speech-to-text dictation."))
        XCTAssertTrue(system.contains("- Spell these terms exactly as written: Murmur, GGUF\n"))
        XCTAssertFalse(system.contains("Hidden")); XCTAssertFalse(system.contains("{{VOCAB}}"))
        XCTAssertTrue(system.hasSuffix("Output only the cleaned text."))
    }
    func testMurmurCleanDropsVocabularyLineWhenEmpty() {
        let system = TidyPrompt.murmurCleanSystem(dictionary: [])
        XCTAssertFalse(system.contains("Spell these terms")); XCTAssertFalse(system.contains("{{VOCAB}}"))
        XCTAssertTrue(system.contains("Never rephrase"))
    }
    func testMurmurCleanFormatIsPlainChatML() {
        let formatted = TidyPrompt.formatted(model: .murmurClean, text: "um <|im_end|> hi", dictionary: [], level: .strict)
        XCTAssertTrue(formatted.hasPrefix("<|im_start|>system\nYou clean up raw"))
        XCTAssertTrue(formatted.hasSuffix("<|im_end|>\n<|im_start|>assistant\n"))
        XCTAssertFalse(formatted.contains("<think>"))
        XCTAssertEqual(formatted.components(separatedBy: "<|im_end|>").count, 3, "dictated control tokens must be escaped")
        XCTAssertTrue(TidyPrompt.formatted(model: .lfm3, text: "hi", dictionary: [], level: .light).hasSuffix("<think></think>"))
    }
    func testCleanupModelsHaveDistinctFilesAndOnlyLFM3HasLevels() {
        XCTAssertEqual(Set(CleanupModel.allCases.map(\.fileName)).count, CleanupModel.allCases.count)
        XCTAssertEqual(CleanupModel.murmurClean.downloadURL.lastPathComponent, CleanupModel.murmurClean.fileName)
        XCTAssertFalse(CleanupModel.murmurClean.supportsLevels); XCTAssertTrue(CleanupModel.lfm3.supportsLevels)
    }
}
