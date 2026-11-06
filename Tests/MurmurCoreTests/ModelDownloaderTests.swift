import CryptoKit
import XCTest
@testable import MurmurCore

final class ModelDownloaderTests: XCTestCase {
    private let source = URL(string: "https://example.com/model.gguf")!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    // MARK: Success

    func testDownloadWritesTheFileAndReportsProgress() async throws {
        let folder = try makeFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("model.gguf")
        let body = ggufBody(4096)
        StubURLProtocol.handler = { _ in .init(status: 200, body: body) }
        let progress = ProgressRecorder()
        let downloader = ModelDownloader(configuration: .stubbed, expectedBytes: Int64(body.count))

        try await downloader.download(from: source, to: destination, expectedSHA256: sha256(body), progress: { progress.record($0) })

        XCTAssertEqual(try Data(contentsOf: destination), body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelDownloader.partURL(for: destination).path), "the .part file is moved into place")
        XCTAssertEqual(progress.values.last, 1)
        XCTAssertTrue(progress.values.allSatisfy { (0...1).contains($0) })
        XCTAssertNil(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "Range"), "a fresh download asks for the whole file")
    }

    func testANonGGUFBodyIsRejectedAndDeleted() async throws {
        let folder = try makeFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("model.gguf")
        StubURLProtocol.handler = { _ in .init(status: 200, body: Data("<html>not a model</html>".utf8)) }

        await XCTAssertThrowsErrorAsync(try await ModelDownloader(configuration: .stubbed).download(from: source, to: destination)) { error in
            XCTAssertTrue(error.localizedDescription.contains("not a GGUF"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelDownloader.partURL(for: destination).path))
    }

    // MARK: Resume

    func testResumeSendsARangeHeaderAndAppendsToThePartFile() async throws {
        let folder = try makeFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("model.gguf")
        let head = ggufBody(100), tail = Data(repeating: 2, count: 900)
        try head.write(to: ModelDownloader.partURL(for: destination))
        StubURLProtocol.handler = { _ in .init(status: 206, body: tail) }

        try await ModelDownloader(configuration: .stubbed).download(from: source, to: destination)

        XCTAssertEqual(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "Range"), "bytes=\(head.count)-")
        XCTAssertEqual(try Data(contentsOf: destination), head + tail)
    }

    func testServerIgnoringTheRangeHeaderRestartsFromZero() async throws {
        let folder = try makeFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("model.gguf")
        let body = ggufBody(900)
        try ggufBody(100).write(to: ModelDownloader.partURL(for: destination))
        StubURLProtocol.handler = { _ in .init(status: 200, body: body) }

        try await ModelDownloader(configuration: .stubbed).download(from: source, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), body, "a 200 body replaces the .part file instead of being appended to it")
    }

    func testA416ResponseRestartsTheDownloadFromZero() async throws {
        let folder = try makeFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("model.gguf")
        let body = ggufBody(900)
        try Data(repeating: 9, count: 5000).write(to: ModelDownloader.partURL(for: destination))
        StubURLProtocol.handler = { request in
            request.value(forHTTPHeaderField: "Range") == nil ? .init(status: 200, body: body) : .init(status: 416, body: Data())
        }

        try await ModelDownloader(configuration: .stubbed).download(from: source, to: destination)

        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        XCTAssertEqual(try Data(contentsOf: destination), body)
    }

    // MARK: Failures

    func testChecksumMismatchDeletesTheFileAndThrows() async throws {
        let folder = try makeFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("model.gguf")
        StubURLProtocol.handler = { _ in .init(status: 200, body: self.ggufBody(64)) }

        await XCTAssertThrowsErrorAsync(try await ModelDownloader(configuration: .stubbed).download(from: source, to: destination, expectedSHA256: String(repeating: "0", count: 64))) { error in
            XCTAssertTrue(error.localizedDescription.contains("integrity"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelDownloader.partURL(for: destination).path))
    }

    func testHTTPErrorThrowsAndWritesNothing() async throws {
        let folder = try makeFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("model.gguf")
        StubURLProtocol.handler = { _ in .init(status: 404, body: Data("not found".utf8)) }

        await XCTAssertThrowsErrorAsync(try await ModelDownloader(configuration: .stubbed).download(from: source, to: destination)) { error in
            XCTAssertTrue(error.localizedDescription.contains("404"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: Cancellation

    func testCancellationKeepsThePartFileForResume() async throws {
        let folder = try makeFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("model.gguf")
        let part = ModelDownloader.partURL(for: destination)
        let delivered = expectation(description: "body delivered")
        StubURLProtocol.handler = { _ in .init(status: 200, body: self.ggufBody(1 << 20), finishes: false) }
        StubURLProtocol.onBodyDelivered = { delivered.fulfill() }

        let task = Task { try await ModelDownloader(configuration: .stubbed).download(from: self.source, to: destination) }
        await fulfillment(of: [delivered], timeout: 5)
        for _ in 0..<200 where fileSize(part) == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        task.cancel()
        do {
            try await task.value
            XCTFail("a cancelled download must not report success")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }

        XCTAssertGreaterThan(fileSize(part), 0, "the bytes received before cancelling are kept for the next attempt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: Storage

    func testStalePartFilesAreRemovedAndFreshOnesKept() throws {
        let folder = try makeFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let stale = folder.appendingPathComponent("old.gguf.part"), fresh = folder.appendingPathComponent("new.gguf.part")
        try Data("x".utf8).write(to: stale)
        try Data("x".utf8).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 24 * 60 * 60)], ofItemAtPath: stale.path)

        XCTAssertEqual(ModelStorage.removeStalePartials(in: folder), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testBuiltInModelsArePinnedToACommitAndChecksum() {
        for model in CleanupModel.builtIn {
            guard let revision = model.revision, let checksum = model.sha256 else { return XCTFail("\(model) is not pinned") }
            XCTAssertEqual(revision.count, 40, "\(model) revision is a commit sha")
            XCTAssertEqual(checksum.count, 64, "\(model) checksum is a SHA-256")
            XCTAssertTrue(model.downloadURL.absoluteString.contains("/resolve/\(revision)/"), model.downloadURL.absoluteString)
            XCTAssertEqual(model.downloadURL.lastPathComponent, model.fileName)
        }
        XCTAssertNil(CleanupModel.custom.revision)
        XCTAssertNil(CleanupModel.custom.sha256)
    }

    // MARK: Protocol plumbing

    func testTheTwoPrepareMethodsForwardToEachOther() async throws {
        let progressOnly = ProgressOnlyTidier(counter: CallCounter())
        try await (progressOnly as any TextTidying).prepare()
        XCTAssertEqual(progressOnly.counter.count, 1, "prepare() reaches a tidier that only implements the progress variant")

        let plainOnly = PlainOnlyTidier(counter: CallCounter())
        try await (plainOnly as any TextTidying).prepare(progress: { _ in })
        XCTAssertEqual(plainOnly.counter.count, 1, "prepare(progress:) reaches a tidier that only implements prepare()")
    }

    // MARK: Helpers

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func ggufBody(_ count: Int) -> Data { Data("GGUF".utf8) + Data(repeating: 7, count: count) }
    private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// `URL.resourceValues` caches, so a poll on the same URL would never see the file grow.
    private func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}

private func XCTAssertThrowsErrorAsync(_ expression: @autoclosure () async throws -> some Any, file: StaticString = #filePath, line: UInt = #line, _ handler: (Error) -> Void) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
    func record(_ value: Double) { lock.lock(); storage.append(value); lock.unlock() }
}

private final class CallCounter: @unchecked Sendable { var count = 0 }

private struct ProgressOnlyTidier: TextTidying {
    let counter: CallCounter
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws { counter.count += 1; progress(1) }
    func tidy(_ text: String, dictionary: [DictionaryEntry], level: CleanupLevel) async throws -> String { text }
}

private struct PlainOnlyTidier: TextTidying {
    let counter: CallCounter
    func prepare() async throws { counter.count += 1 }
    func tidy(_ text: String, dictionary: [DictionaryEntry], level: CleanupLevel) async throws -> String { text }
}

/// Answers every request from a closure, so a test can script a 206, a 416 followed by a 200, or a body that never ends.
final class StubURLProtocol: URLProtocol {
    struct Stub {
        var status = 200
        var body = Data()
        /// false leaves the transfer open, so a test can cancel it mid-flight.
        var finishes = true
    }
    static var handler: (URLRequest) -> Stub = { _ in Stub() }
    static var requests: [URLRequest] = []
    static var onBodyDelivered: (() -> Void)?

    static func reset() {
        handler = { _ in Stub() }
        requests = []
        onBodyDelivered = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        StubURLProtocol.requests.append(request)
        let stub = StubURLProtocol.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(stub.body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
            StubURLProtocol.onBodyDelivered?()
        }
        if stub.finishes { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}

extension URLSessionConfiguration {
    static var stubbed: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }
}
