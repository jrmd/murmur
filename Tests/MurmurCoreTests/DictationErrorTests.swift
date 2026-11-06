import XCTest
@testable import MurmurCore

final class DictationErrorTests: XCTestCase {
    func testKindAndMessageAreKept() {
        let error = DictationError(.microphoneDenied, "Microphone access was denied.")
        XCTAssertEqual(error.kind, .microphoneDenied)
        XCTAssertEqual(error.message, "Microphone access was denied.")
        XCTAssertEqual(error.errorDescription, "Microphone access was denied.")
    }
    func testEqualityComparesKindAndMessage() {
        XCTAssertEqual(DictationError(.busy, "Dictation is busy."), DictationError(.busy, "Dictation is busy."))
        XCTAssertNotEqual(DictationError(.busy, "Dictation is busy."), DictationError(.busy, "Something else."))
        XCTAssertNotEqual(DictationError(.busy, "Dictation is busy."), DictationError(.other, "Dictation is busy."))
    }
    func testEveryKindIsDistinct() {
        let kinds: [DictationError.Kind] = [.microphoneDenied, .noMicrophone, .microphoneChanged, .modelsNotReady, .modelChanged, .busy, .other]
        XCTAssertEqual(Set(kinds.map { "\($0)" }).count, kinds.count)
    }
    func testStateCarriesTheTypedError() {
        let error = DictationError(.noMicrophone, "The microphone format is unavailable.")
        XCTAssertEqual(DictationState.error(error), .error(error))
        XCTAssertNotEqual(DictationState.error(error), .error(DictationError(.other, error.message)))
        XCTAssertNotEqual(DictationState.error(error), .idle)
    }
    func testLocalizedDescriptionIsTheMessage() {
        let error: Error = DictationError(.modelChanged, "The model changed while it was loading.")
        XCTAssertEqual(error.localizedDescription, "The model changed while it was loading.")
    }
    func testErrorCrossesTaskBoundaries() async {
        let error = DictationError(.modelsNotReady, "Prepare models before recording.")
        let echoed = await Task { error }.value
        XCTAssertEqual(echoed, error)
    }
}
