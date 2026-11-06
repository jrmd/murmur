import XCTest
@testable import MurmurCore

private struct StubTidier: TextTidying {
    var result: String?
    var failure: String?
    func prepare() async throws {}
    func tidy(_ text: String, dictionary: [DictionaryEntry], level: CleanupLevel) async throws -> String {
        if let failure { throw CoreError.message(failure) }
        return result ?? text
    }
}

final class PipelineTests: XCTestCase {
    func testRecordingLimitsMatchFluidAudio() {
        XCTAssertEqual(PipelineRules.minimumSamples, 4_800, "0.3 s at 16 kHz, the shortest audio FluidAudio accepts")
        XCTAssertEqual(PipelineRules.maximumSamples, 5 * 60 * 16_000)
        XCTAssertEqual(Double(PipelineRules.maximumSamples) / Double(PipelineRules.sampleRate), 300)
    }
    func testShortAudioIsNotTranscribable() {
        XCTAssertFalse(PipelineRules.isTranscribable(0))
        XCTAssertFalse(PipelineRules.isTranscribable(PipelineRules.minimumSamples - 1))
        XCTAssertTrue(PipelineRules.isTranscribable(PipelineRules.minimumSamples))
        XCTAssertTrue(PipelineRules.isTranscribable(PipelineRules.minimumSamples + 1))
    }
    func testCaptureStopsAcceptingAtTheCap() {
        XCTAssertTrue(PipelineRules.accepts(0))
        XCTAssertTrue(PipelineRules.accepts(PipelineRules.maximumSamples - 1))
        XCTAssertFalse(PipelineRules.accepts(PipelineRules.maximumSamples))
        XCTAssertFalse(PipelineRules.accepts(PipelineRules.maximumSamples + 1))
    }
    func testOvertakenStartIsNotCurrent() {
        XCTAssertTrue(PipelineRules.isCurrent(start: 3, current: 3))
        XCTAssertFalse(PipelineRules.isCurrent(start: 3, current: 4), "a stop or cancel bumped the token while start() waited")
    }
    func testResultKeepsTheOldInitializerAndReportsCleanupDuration() {
        let plain = DictationResult(raw: "a", final: "a")
        XCTAssertNil(plain.cleanupFailure); XCTAssertNil(plain.cleanupDuration)
        let timed = DictationResult(raw: "a", final: "b", cleanupFailure: "boom", cleanupDuration: 0.25)
        XCTAssertEqual(timed.cleanupFailure, "boom"); XCTAssertEqual(timed.cleanupDuration, 0.25)
    }
    func testTidyFallsBackToTheTranscriptWhenCleanupFails() async throws {
        let tidied = try await DictationPipeline.tidy("hello there", using: StubTidier(failure: "model exploded"), dictionary: [], level: .balanced)
        XCTAssertEqual(tidied.text, "hello there")
        XCTAssertEqual(tidied.failure, "model exploded")
        XCTAssertGreaterThanOrEqual(tidied.duration, 0)
    }
    func testTidyReturnsTheCleanedText() async throws {
        let tidied = try await DictationPipeline.tidy("um hello", using: StubTidier(result: "Hello."), dictionary: [], level: .balanced)
        XCTAssertEqual(tidied.text, "Hello."); XCTAssertNil(tidied.failure)
        XCTAssertGreaterThanOrEqual(tidied.duration, 0)
    }
    func testStopWithNothingRecordingIsANoOp() async throws {
        let pipeline = DictationPipeline(tidier: StubTidier())
        let result = try await pipeline.stop()
        XCTAssertEqual(result.raw, ""); XCTAssertEqual(result.final, "")
        XCTAssertNil(result.cleanupDuration)
        let state = await latestState(of: pipeline)
        XCTAssertEqual(state, .idle)
    }
    func testRepeatedStopStaysANoOp() async throws {
        let pipeline = DictationPipeline(tidier: StubTidier())
        _ = try await pipeline.stop()
        let second = try await pipeline.stop()
        XCTAssertEqual(second.final, "")
        let state = await latestState(of: pipeline)
        XCTAssertEqual(state, .idle)
    }
    func testCancelReturnsToIdle() async throws {
        let pipeline = DictationPipeline(tidier: StubTidier())
        await pipeline.cancel()
        let state = await latestState(of: pipeline)
        XCTAssertEqual(state, .idle)
        let result = try await pipeline.stop()
        XCTAssertEqual(result.final, "")
    }
    func testStartWithoutModelsThrowsModelsNotReady() async {
        let pipeline = DictationPipeline(tidier: StubTidier())
        do { try await pipeline.start(); XCTFail("start() must need a prepared model") }
        catch let error as DictationError {
            XCTAssertEqual(error.kind, .modelsNotReady)
            XCTAssertTrue(error.message.contains("Prepare models"))
        } catch { XCTFail("start() must throw a DictationError, got \(error)") }
        let state = await latestState(of: pipeline)
        XCTAssertEqual(state, .idle)
    }
    private func latestState(of pipeline: DictationPipeline) async -> DictationState? {
        let stream = await pipeline.state
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
}
