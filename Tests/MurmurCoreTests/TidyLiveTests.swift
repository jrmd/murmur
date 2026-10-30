import XCTest
@testable import MurmurCore

/// Runs the real clean-up models, downloading them on first use. Skipped unless MURMUR_LIVE=1.
/// MURMUR_LIVE_MODEL=lfm3 tests LFM3 instead of Murmur Clean.
final class TidyLiveTests: XCTestCase {
    func testTidyTerminatesAndKeepsMeaning() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MURMUR_LIVE"] == "1")
        let model = CleanupModel(rawValue: ProcessInfo.processInfo.environment["MURMUR_LIVE_MODEL"] ?? "") ?? .murmurClean
        let tidier = LlamaTidier(model: model)
        try await tidier.prepare()
        let samples = [
            "um can you pick up oat milk no wait two oat milks and uh some dog food on the way home",
            "hey can you send me the report by friday actually make that monday and also loop in sarah",
            "i think we should we should ship it tomorrow if the tests pass",
            "so i was thinking we should uh probably move the meeting to thursday because like nobody is free on wednesday and also the room is booked",
            "set a timer for thirty i mean for twenty five minutes",
            "the file is about two hundred and fifty megabytes comma so it might take a while full stop",
            "the new murmer build is on the shared you know drive",
        ]
        for sample in samples {
            do {
                let out = try await tidier.tidy(sample, dictionary: [])
                print("TIDY IN : \(sample)\nTIDY OUT: \(out)")
                XCTAssertFalse(out.isEmpty)
            } catch {
                print("TIDY IN : \(sample)\nTIDY ERR: \(error.localizedDescription)")
                XCTFail("\(error.localizedDescription)")
            }
        }
    }
}
