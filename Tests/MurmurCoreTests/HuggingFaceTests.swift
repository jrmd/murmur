import XCTest
@testable import MurmurCore

/// Serves canned replies so the Hugging Face listing can be tested without the network.
final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        guard let handler = Self.handler else { return }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class HuggingFaceTests: XCTestCase {
    private let sha = "0123456789abcdef0123456789abcdef01234567"

    override func setUp() {
        super.setUp()
        StubURLProtocol.handler = nil
        StubURLProtocol.requests = []
    }
    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.requests = []
        super.tearDown()
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func reply(_ status: Int, _ body: String) {
        StubURLProtocol.handler = { _ in (status, Data(body.utf8)) }
    }
    /// The message a caller would show, or nil when the call succeeded.
    private func message(_ body: () async throws -> Void) async -> String? {
        do { try await body(); return nil } catch { return error.localizedDescription }
    }

    // MARK: Listing

    func testListingReturnsFilesAndPinsTheCommit() async throws {
        reply(200, """
        {"sha":"\(sha)","siblings":[{"rfilename":"README.md"},{"rfilename":"m-Q8_0.gguf","size":1760},
        {"rfilename":"m-Q4_K_M.gguf","size":1050},{"rfilename":"mmproj-F16.gguf","size":300}]}
        """)
        let found = try await HuggingFace.listGGUFRepository(repo: "owner/name-GGUF", session: session())
        XCTAssertEqual(found.files.map(\.name), ["m-Q4_K_M.gguf", "m-Q8_0.gguf"])
        XCTAssertEqual(found.revision, sha)
        XCTAssertEqual(StubURLProtocol.requests.first?.url?.absoluteString, "https://huggingface.co/api/models/owner/name-GGUF?blobs=true")
        let wrapper = try await HuggingFace.listGGUFFiles(repo: "owner/name-GGUF", session: session())
        XCTAssertEqual(wrapper.map(\.name), ["m-Q4_K_M.gguf", "m-Q8_0.gguf"])
    }
    func testListingWithoutACommitFallsBackToMain() async throws {
        reply(200, #"{"siblings":[{"rfilename":"m.gguf","size":1}]}"#)
        let found = try await HuggingFace.listGGUFRepository(repo: "owner/name-GGUF", session: session())
        XCTAssertNil(found.revision)
        XCTAssertEqual(CustomCleanupModel(repo: "owner/name-GGUF", fileName: "m.gguf", revision: found.revision).downloadURL?.absoluteString,
                       "https://huggingface.co/owner/name-GGUF/resolve/main/m.gguf")
    }
    func testNonHexCommitIsIgnored() async throws {
        reply(200, #"{"sha":"not-a-commit","siblings":[{"rfilename":"m.gguf","size":1}]}"#)
        let found = try await HuggingFace.listGGUFRepository(repo: "owner/name-GGUF", session: session())
        XCTAssertNil(found.revision)
    }
    func testPrivateAndGatedReposExplainThemselves() async {
        for status in [401, 403] {
            reply(status, "{}")
            let text = await message { _ = try await HuggingFace.listGGUFFiles(repo: "owner/name-GGUF", session: session()) }
            XCTAssertTrue(text?.contains("private") == true, "\(status): \(text ?? "nil")")
        }
    }
    func testMissingModelSaysSo() async {
        reply(404, "{}")
        let text = await message { _ = try await HuggingFace.listGGUFFiles(repo: "owner/name-GGUF", session: session()) }
        XCTAssertEqual(text, "Hugging Face has no model called owner/name-GGUF.")
    }
    func testServerErrorsAreReported() async {
        reply(500, "{}")
        let text = await message { _ = try await HuggingFace.listGGUFFiles(repo: "owner/name-GGUF", session: session()) }
        XCTAssertEqual(text, "Hugging Face returned an error (500). Try again in a moment.")
    }
    func testMalformedJSONThrowsAFriendlyError() async {
        reply(200, #"{"siblings":"nope"}"#)
        let text = await message { _ = try await HuggingFace.listGGUFFiles(repo: "owner/name-GGUF", session: session()) }
        XCTAssertEqual(text, "Hugging Face sent a reply Murmur couldn’t read. Try again in a moment.")
        XCTAssertFalse(text?.contains("DecodingError") == true)
    }
    func testListingWithoutSiblingsThrows() async {
        reply(200, #"{"sha":"\#(sha)"}"#)
        let text = await message { _ = try await HuggingFace.listGGUFFiles(repo: "owner/name-GGUF", session: session()) }
        XCTAssertEqual(text, "Hugging Face didn’t list any files for owner/name-GGUF. Check the link and try again.")
    }
    func testOfflineAndTimeoutsAreFriendly() async {
        for code in [URLError.notConnectedToInternet, .timedOut, .cannotFindHost] {
            StubURLProtocol.handler = { _ in throw URLError(code) }
            let text = await message { _ = try await HuggingFace.listGGUFFiles(repo: "owner/name-GGUF", session: session()) }
            XCTAssertNotNil(text, "\(code)")
            XCTAssertFalse(text?.contains("NSURLError") == true, "\(code): \(text ?? "nil")")
            if code == .timedOut { XCTAssertTrue(text?.contains("too long") == true, text ?? "nil") }
            else { XCTAssertTrue(text?.contains("offline") == true, text ?? "nil") }
        }
    }
    func testInvalidRepoNeverReachesTheNetwork() async {
        let text = await message { _ = try await HuggingFace.listGGUFFiles(repo: "not a repo", session: session()) }
        XCTAssertEqual(text, "That is not a valid Hugging Face model name.")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    // MARK: Sizes

    func testLFSSizeWinsOverPlainSize() throws {
        let json = """
        {"siblings":[{"rfilename":"m-Q4_K_M.gguf","size":10,"lfs":{"size":1050}},{"rfilename":"m-Q8_0.gguf","size":1760},
        {"rfilename":"m-F16.gguf","lfs":{"size":3000}}]}
        """
        let files = try HuggingFace.ggufFiles(in: Data(json.utf8))
        XCTAssertEqual(files.map(\.name), ["m-Q4_K_M.gguf", "m-Q8_0.gguf", "m-F16.gguf"])
        XCTAssertEqual(files.map(\.size), [1050, 1760, 3000])
    }

    // MARK: Revision pinning

    func testRevisionPinsTheDownloadURLAndKeepsTheLocalPath() {
        let pinned = CustomCleanupModel(repo: "owner/name-GGUF", fileName: "name-Q4_K_M.gguf", revision: sha)
        XCTAssertEqual(pinned.downloadURL?.absoluteString, "https://huggingface.co/owner/name-GGUF/resolve/\(sha)/name-Q4_K_M.gguf")
        XCTAssertEqual(pinned.localURL, CustomCleanupModel(repo: "owner/name-GGUF", fileName: "name-Q4_K_M.gguf").localURL)
        for bad in ["main", "abc", "not-hex-1234567", String(repeating: "a", count: 65), ""] {
            XCTAssertFalse(HuggingFace.isValidRevision(bad), bad)
            XCTAssertEqual(CustomCleanupModel(repo: "owner/name-GGUF", fileName: "name-Q4_K_M.gguf", revision: bad).downloadURL?.absoluteString,
                           "https://huggingface.co/owner/name-GGUF/resolve/main/name-Q4_K_M.gguf", bad)
        }
        XCTAssertTrue(HuggingFace.isValidRevision(sha))
    }

    // MARK: Storage

    func testOldStoredJSONWithoutRevisionStillDecodes() throws {
        let json = #"{"repo":"owner/name-GGUF","fileName":"name-Q4_K_M.gguf","systemPrompt":"hi","sizeBytes":42}"#
        let model = try JSONDecoder().decode(CustomCleanupModel.self, from: Data(json.utf8))
        XCTAssertNil(model.revision)
        XCTAssertEqual(model.sizeBytes, 42)
        XCTAssertEqual(model.downloadURL?.absoluteString, "https://huggingface.co/owner/name-GGUF/resolve/main/name-Q4_K_M.gguf")
    }
    func testStoredModelRoundTripsThroughInjectedDefaults() {
        let name = "murmur-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertNil(CustomCleanupModel.stored(in: defaults))
        let model = CustomCleanupModel(repo: "owner/name-GGUF", fileName: "name-Q4_K_M.gguf", systemPrompt: "be brief", sizeBytes: 7, revision: sha)
        CustomCleanupModel.store(model, in: defaults)
        XCTAssertEqual(CustomCleanupModel.stored(in: defaults), model)
        CustomCleanupModel.store(nil, in: defaults)
        XCTAssertNil(CustomCleanupModel.stored(in: defaults))
    }
    func testStoredModelIgnoresInvalidAndUnreadableValues() {
        let name = "murmur-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("not json".utf8), forKey: "customCleanupModel")
        XCTAssertNil(CustomCleanupModel.stored(in: defaults))
        defaults.set(Data(#"{"repo":"owner/../x","fileName":"x.gguf","systemPrompt":"hi"}"#.utf8), forKey: "customCleanupModel")
        XCTAssertNil(CustomCleanupModel.stored(in: defaults))
        defaults.set(Data(#"{"repo":"owner/name-GGUF","fileName":"x.bin","systemPrompt":"hi"}"#.utf8), forKey: "customCleanupModel")
        XCTAssertNil(CustomCleanupModel.stored(in: defaults))
    }

    // MARK: Links

    func testSchemeLessAndShortLinksParse() {
        XCTAssertEqual(HuggingFace.parse("huggingface.co/a/b"), .init(repo: "a/b", fileName: nil))
        XCTAssertEqual(HuggingFace.parse("www.huggingface.co/a/b/blob/main/model.gguf"), .init(repo: "a/b", fileName: "model.gguf"))
        XCTAssertEqual(HuggingFace.parse("hf.co/a/b"), .init(repo: "a/b", fileName: nil))
        XCTAssertEqual(HuggingFace.parse("https://hf.co/a/b/resolve/main/model.gguf"), .init(repo: "a/b", fileName: "model.gguf"))
        XCTAssertEqual(HuggingFace.parse("huggingface.co/a/b/tree/main"), .init(repo: "a/b", fileName: nil))
        for input in ["hf.co.evil.example/a/b", "huggingface.co/spaces/x/y", "hf.co", "huggingface.co/a", "ftp://huggingface.co/a/b", "huggingface.co/a/b c"] {
            XCTAssertNil(HuggingFace.parse(input), input)
        }
    }
}
