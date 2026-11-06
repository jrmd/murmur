import XCTest
@testable import MurmurCore

/// LFM3 answers and then keeps talking. These are the pure guards that keep its commentary out of the cleanup, and the
/// prompt shape that stops it from treating the worked example as conversation history.
final class TidyCommentaryTests: XCTestCase {
    // MARK: Commentary

    func testAParagraphOfReasoningIsDropped() {
        let raw = "So I was thinking we should move the meeting to Thursday.\n\n[Note: I removed \"uh\" and fixed the punctuation.]"
        XCTAssertEqual(TidyPrompt.trimmingCommentary(raw), "So I was thinking we should move the meeting to Thursday.")
    }

    func testAParentheticalAsideIsDropped() {
        XCTAssertEqual(TidyPrompt.trimmingCommentary("The new Murmer build is on the shared drive. (Wait, \"you know\" is filler.)"), "The new Murmer build is on the shared drive.")
        XCTAssertEqual(TidyPrompt.trimmingCommentary("Set a timer for 25 minutes. (or: set a timer for twenty-five minutes)"), "Set a timer for 25 minutes.")
    }

    func testACleanAnswerIsLeftAlone() {
        for answer in ["Can you pick up two oat milks and some dog food on the way home?", "The file is about 250 megabytes, so it might take a while.", "Set a timer for 25 minutes."] {
            XCTAssertEqual(TidyPrompt.trimmingCommentary(answer), answer)
        }
    }

    func testADictatedParentheticalSurvives() {
        let answer = "The file (about 250 megabytes) is on the shared drive."
        XCTAssertEqual(TidyPrompt.trimmingCommentary(answer), answer)
    }

    func testTheEarliestMarkerWins() {
        let raw = "Ship it tomorrow. (Hmm, the tests pass?)\n\nLet me re-read the dictation."
        XCTAssertEqual(TidyPrompt.trimmingCommentary(raw), "Ship it tomorrow.")
    }

    // MARK: Repetition

    func testALoopedPhraseIsDetected() {
        XCTAssertTrue(TidyPrompt.isRepeating(String(repeating: "also, the room is booked. ", count: 5)))
    }

    func testNormalProseIsNotARepetition() {
        XCTAssertFalse(TidyPrompt.isRepeating("So I was thinking we should probably move the meeting to Thursday because nobody is free on Wednesday and also the room is booked."))
        XCTAssertFalse(TidyPrompt.isRepeating("Set a timer for 25 minutes."))
        XCTAssertFalse(TidyPrompt.isRepeating(""))
    }

    func testASingleRepeatIsNotALoop() {
        XCTAssertFalse(TidyPrompt.isRepeating(String(repeating: "also, the room is booked. ", count: 2)))
    }

    // MARK: Salvage

    func testOnlyAFinishedSentenceIsSalvaged() {
        XCTAssertTrue(TidyPrompt.isCompleteCleanup("Set a timer for 25 minutes."))
        XCTAssertTrue(TidyPrompt.isCompleteCleanup("Can you send the report by Monday?"))
        XCTAssertFalse(TidyPrompt.isCompleteCleanup("Set a timer for 25 minutes, I mean"))
        XCTAssertFalse(TidyPrompt.isCompleteCleanup(""))
    }

    // MARK: Prompt shape

    func testTheWorkedExampleIsNotAConversationTurn() {
        let segments = TidyPrompt.segments(text: "hi", dictionary: [], level: .balanced)
        XCTAssertEqual(segments.count, 5)
        XCTAssertTrue(segments[1].text.contains("Example dictation:"), "the example belongs in the system turn")
        XCTAssertFalse(segments[1].parseSpecial)
        let prompt = TidyPrompt.joined(segments)
        XCTAssertEqual(prompt.components(separatedBy: "<|im_start|>user").count - 1, 1, "one user turn, so the model has no earlier turn to continue")
        XCTAssertEqual(prompt.components(separatedBy: "<|im_start|>assistant").count - 1, 1)
        XCTAssertTrue(segments[4].parseSpecial && segments[4].text.hasPrefix("<|im_end|>\n<|im_start|>assistant\n"), "the answer starts straight after the assistant marker")
    }
}
