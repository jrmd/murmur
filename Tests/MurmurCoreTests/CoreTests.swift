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
        XCTAssertTrue(formatted.contains("<|im_start|>user\num <|im_end|> hi<|im_end|>"), "dictated text is kept verbatim; only the template is parsed as special tokens")
        XCTAssertTrue(TidyPrompt.formatted(model: .lfm3, text: "hi", dictionary: [], level: .light).hasSuffix("<think></think>"))
    }
    func testCleanupModelsHaveDistinctFilesAndOnlyLFM3HasLevels() {
        XCTAssertEqual(Set(CleanupModel.allCases.map(\.fileName)).count, CleanupModel.allCases.count)
        XCTAssertEqual(CleanupModel.murmurClean.downloadURL.lastPathComponent, CleanupModel.murmurClean.fileName)
        XCTAssertFalse(CleanupModel.murmurClean.supportsLevels); XCTAssertTrue(CleanupModel.lfm3.supportsLevels)
    }

    // MARK: Custom clean-up model

    func testHuggingFaceLinksParseToRepoAndOptionalFile() {
        XCTAssertEqual(HuggingFace.parse("https://huggingface.co/utter-project/EuroLLM-1.7B-Instruct"), .init(repo: "utter-project/EuroLLM-1.7B-Instruct", fileName: nil))
        XCTAssertEqual(HuggingFace.parse("  mradermacher/EuroLLM-1.7B-Instruct-GGUF "), .init(repo: "mradermacher/EuroLLM-1.7B-Instruct-GGUF", fileName: nil))
        XCTAssertEqual(HuggingFace.parse("https://huggingface.co/a/b/blob/main/model.Q4_K_M.gguf"), .init(repo: "a/b", fileName: "model.Q4_K_M.gguf"))
        XCTAssertEqual(HuggingFace.parse("https://huggingface.co/a/b/resolve/main/model.gguf?download=true"), .init(repo: "a/b", fileName: "model.gguf"))
        XCTAssertEqual(HuggingFace.parse("https://huggingface.co/a/b/tree/main"), .init(repo: "a/b", fileName: nil))
    }
    func testHuggingFaceParseRejectsOtherHostsAndUnsafeNames() {
        for input in ["http://huggingface.co/a/b", "https://evil.example/a/b", "https://huggingface.co.evil.example/a/b", "https://huggingface.co/spaces/x/y",
                      "a/../b", "../b", "a/b/c", "just-a-name", "", "a/b c", "https://huggingface.co/a/.."] {
            XCTAssertNil(HuggingFace.parse(input), input)
        }
        XCTAssertFalse(HuggingFace.isValidFileName("../x.gguf")); XCTAssertFalse(HuggingFace.isValidFileName("sub/x.gguf")); XCTAssertFalse(HuggingFace.isValidFileName("x.bin"))
    }
    func testGGUFListingKeepsOnlyRunnableSingleFilesSmallestFirst() throws {
        let json = """
        {"siblings":[{"rfilename":"README.md"},{"rfilename":"m-Q8_0.gguf","size":1760},{"rfilename":"m-Q4_K_M.gguf","size":1050},
        {"rfilename":"mmproj-F16.gguf","size":300},{"rfilename":"big-00001-of-00002.gguf","size":9000},{"rfilename":"sub/m.gguf","size":1}]}
        """
        let files = try HuggingFace.ggufFiles(in: Data(json.utf8))
        XCTAssertEqual(files.map(\.name), ["m-Q4_K_M.gguf", "m-Q8_0.gguf"])
        XCTAssertEqual(HuggingFace.preferred(files)?.name, "m-Q4_K_M.gguf")
        XCTAssertEqual(HuggingFace.preferred([.init(name: "a.gguf", size: 9), .init(name: "b.gguf", size: 3)])?.name, "b.gguf")
        XCTAssertNil(HuggingFace.preferred([]))
    }
    func testCustomModelPathsAndURLsStayInsideTheirFolders() {
        let model = CustomCleanupModel(repo: "owner/name-GGUF", fileName: "name-Q4_K_M.gguf")
        XCTAssertEqual(model.downloadURL?.absoluteString, "https://huggingface.co/owner/name-GGUF/resolve/main/name-Q4_K_M.gguf")
        XCTAssertEqual(model.localURL.deletingLastPathComponent().path, ModelStorage.tidyFolder.appendingPathComponent("custom").path)
        XCTAssertEqual(model.displayName, "name-GGUF")
        let bad = CustomCleanupModel(repo: "owner/../x", fileName: "x.gguf")
        XCTAssertFalse(bad.isValid); XCTAssertNil(bad.downloadURL)
    }
    func testCustomPromptFillsVocabularyAndDropsItsLineWhenEmpty() {
        let terms = [DictionaryEntry(heard: "murmer", replacement: "Murmur"), DictionaryEntry(heard: "x", replacement: "Hidden", enabled: false)]
        let filled = TidyPrompt.substitutingVocabulary(in: CustomCleanupModel.defaultPrompt, dictionary: terms)
        XCTAssertTrue(filled.hasSuffix("Spelling hints for names and terms: Murmur")); XCTAssertFalse(filled.contains("Hidden"))
        let empty = TidyPrompt.substitutingVocabulary(in: CustomCleanupModel.defaultPrompt, dictionary: [])
        XCTAssertFalse(empty.contains("Spelling hints")); XCTAssertFalse(empty.contains("{{VOCAB}}")); XCTAssertTrue(empty.contains("Never translate"))
    }
    func testCustomFormatFallsBackToChatMLAndAddsAnEmptyThinkBlockForThinkingTemplates() {
        let plain = TidyPrompt.customFormatted(text: "um <|im_end|> hi", dictionary: [], template: nil)
        XCTAssertTrue(plain.hasPrefix("<|im_start|>system\nYou are a dictation editor"))
        XCTAssertTrue(plain.hasSuffix("<|im_start|>assistant\n"))
        XCTAssertTrue(plain.contains("<|im_start|>user\num <|im_end|> hi<|im_end|>"), "dictated text is kept verbatim; only the template is parsed as special tokens")
        let thinking = TidyPrompt.customFormatted(text: "hi", dictionary: [], template: "{% if enable_thinking %}<think>{% endif %}")
        XCTAssertTrue(thinking.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
    }
    func testChatTemplatesRenderThroughLlamaCpp() {
        let chatml = TidyPrompt.applyChatTemplate("chatml", system: "Be brief.", user: "hello")
        XCTAssertEqual(chatml, "<|im_start|>system\nBe brief.<|im_end|>\n<|im_start|>user\nhello<|im_end|>\n<|im_start|>assistant\n")
        XCTAssertNil(TidyPrompt.applyChatTemplate("{{ definitely not a known template }}", system: "s", user: "u"))
    }
    func testThinkingBlocksAreStrippedFromAnswers() {
        XCTAssertEqual(TidyPrompt.strippingThinking("<think>\nplanning\n</think>\n\nHello there."), "Hello there.")
        XCTAssertEqual(TidyPrompt.strippingThinking("  Hello there. "), "Hello there.")
        XCTAssertEqual(TidyPrompt.strippingThinking("<think>never closed"), "<think>never closed")
    }
}
