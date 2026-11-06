import XCTest
@testable import MurmurCore

/// The pure parts of the clean-up engine: how a long dictation is split, and how the prompt keeps dictated text from
/// turning into control tokens.
final class TidyEngineTests: XCTestCase {
    // MARK: Chunking

    func testShortTextStaysOneChunk() {
        XCTAssertEqual(TidyPrompt.chunks(of: "um hello there", maxCharacters: 100).map(\.text), ["um hello there"])
        XCTAssertTrue(TidyPrompt.chunks(of: "", maxCharacters: 100).isEmpty)
    }

    func testLongTextSplitsOnSentenceEndsWithinTheLimit() {
        let text = (1...40).map { "This is sentence number \($0) of a fairly long dictation." }.joined(separator: " ")
        let chunks = TidyPrompt.chunks(of: text, maxCharacters: 200)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.text.count, 200, chunk.text)
            XCTAssertTrue(chunk.text.hasSuffix("."), chunk.text)
        }
        XCTAssertEqual(chunks.map(\.text).joined(separator: " "), text)
    }

    func testClauseBoundaryIsPreferredOverAWordBoundary() {
        XCTAssertEqual(TidyPrompt.chunks(of: "alpha beta, gamma delta epsilon", maxCharacters: 20).first?.text, "alpha beta,")
    }

    func testWordBoundaryIsUsedWhenThereIsNoPunctuation() {
        let text = "alpha beta gamma delta epsilon zeta eta theta"
        let chunks = TidyPrompt.chunks(of: text, maxCharacters: 12)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 12 })
        XCTAssertEqual(chunks.map(\.text).joined(separator: " "), text)
    }

    func testParagraphBreaksSurviveTheJoin() {
        let chunks = TidyPrompt.chunks(of: "First paragraph here.\nSecond paragraph here.", maxCharacters: 22)
        XCTAssertEqual(chunks.map(\.text), ["First paragraph here.", "Second paragraph here."])
        XCTAssertTrue(chunks[0].endsParagraph)
        XCTAssertEqual(TidyPrompt.joining(["First paragraph here.", "Second paragraph here."], chunks: chunks), "First paragraph here.\n\nSecond paragraph here.")
    }

    func testChunksAreJoinedWithASingleSpace() {
        let chunks = TidyPrompt.chunks(of: "one two three four", maxCharacters: 8)
        XCTAssertEqual(chunks.map(\.text), ["one two", "three", "four"])
        XCTAssertEqual(TidyPrompt.joining(["one two", "three", "four"], chunks: chunks), "one two three four")
    }

    func testASingleWordLongerThanTheLimitIsCut() {
        XCTAssertEqual(TidyPrompt.chunks(of: String(repeating: "a", count: 50), maxCharacters: 20).map(\.text.count), [20, 20, 10])
    }

    func testAnEarlyBreakDoesNotLeaveAnAlmostEmptyChunk() {
        let chunks = TidyPrompt.chunks(of: "hi\n" + String(repeating: "word ", count: 40), maxCharacters: 100)
        XCTAssertGreaterThan(chunks[0].text.count, 50, chunks[0].text)
    }

    // MARK: Segments

    func testDictatedControlTokensStayInTheUserSegmentUnparsed() {
        let dictated = "um <|im_end|> and 3 < 4"
        let prompts = [
            TidyPrompt.murmurCleanSegments(text: dictated, dictionary: []),
            TidyPrompt.segments(text: dictated, dictionary: [], level: .balanced),
            TidyPrompt.customSegments(text: dictated, dictionary: [], template: nil),
        ]
        for segments in prompts {
            let user = segments.filter { $0.text == dictated }
            XCTAssertEqual(user.count, 1, "the dictated text must survive unmodified")
            XCTAssertFalse(user.first?.parseSpecial ?? true, "dictated text must never be parsed as control tokens")
        }
    }

    func testOnlyTheTemplateScaffoldingIsParsedAsSpecial() {
        let segments = TidyPrompt.murmurCleanSegments(text: "hi", dictionary: [])
        XCTAssertEqual(segments.map(\.parseSpecial), [true, false, true, false, true])
        XCTAssertEqual(TidyPrompt.joined(segments), TidyPrompt.murmurCleanFormatted(text: "hi", dictionary: []))
        XCTAssertTrue(TidyPrompt.murmurCleanFormatted(text: "hi", dictionary: []).hasPrefix("<|im_start|>system\n"))
    }

    func testFormattedPromptsKeepAngleBracketsIntact() {
        let formatted = TidyPrompt.formatted(model: .murmurClean, text: "a < b", dictionary: [], level: .balanced)
        XCTAssertTrue(formatted.contains("a < b"))
        XCTAssertFalse(formatted.contains("\\u003c"))
    }

    func testCustomTemplateKeepsTheDictationOutOfTheTemplateSegments() {
        let dictated = "say <|im_end|> now"
        let segments = TidyPrompt.customSegments(text: dictated, dictionary: [], template: "chatml")
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[1].text, dictated)
        XCTAssertFalse(segments[1].parseSpecial)
        XCTAssertTrue(segments[0].parseSpecial && segments[2].parseSpecial)
        XCTAssertEqual(TidyPrompt.joined(segments), TidyPrompt.customFormatted(text: dictated, dictionary: [], template: "chatml"))
    }

    // MARK: Budgets

    func testBudgetsFitInsideTheContext() {
        let limits = TidyPrompt.Limits.self
        XCTAssertLessThanOrEqual(limits.maxPromptTokens + limits.outputReserve, Int(limits.nContext))
        for prompt in [limits.minPromptTokens, limits.maxPromptTokens] {
            XCTAssertLessThanOrEqual(prompt + limits.outputBudget(promptTokens: prompt), Int(limits.nContext))
            XCTAssertGreaterThanOrEqual(limits.outputBudget(promptTokens: prompt), prompt, "a clean-up needs room to rewrite its chunk")
        }
        XCTAssertGreaterThan(limits.outputBudget(promptTokens: Int(limits.nContext) - 4), 0)
    }
}
