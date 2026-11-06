import Foundation

/// A clean-up model the user pointed Murmur at: one GGUF file from a Hugging Face repo, plus the system prompt to run it with.
public struct CustomCleanupModel: Codable, Equatable, Sendable {
    public var repo: String
    public var fileName: String
    public var systemPrompt: String
    public var sizeBytes: Int64?
    /// The repo commit the file was listed from, so a later download gets the same bytes. Nil means `main`.
    public var revision: String?

    /// Replaced with the dictionary's spellings; a line containing it is dropped when the dictionary is empty.
    public static let vocabularyPlaceholder = "{{VOCAB}}"
    public static let defaultPrompt = """
    You are a dictation editor. Rewrite the user's dictated text as clean written text, in the same language it was spoken in. Never translate. \
    Remove filler words and stutters, and if the speaker corrects themselves keep only the corrected version. Fix punctuation and capitalisation. \
    Keep the speaker's meaning, tone and every question or request; do not summarise or answer anything. Reply with the cleaned text only.
    Spelling hints for names and terms: {{VOCAB}}
    """

    public init(repo: String, fileName: String, systemPrompt: String = CustomCleanupModel.defaultPrompt, sizeBytes: Int64? = nil, revision: String? = nil) {
        self.repo = repo; self.fileName = fileName; self.systemPrompt = systemPrompt; self.sizeBytes = sizeBytes; self.revision = revision
    }

    private static let key = "customCleanupModel"
    /// The saved choice, or nil when none was made or the stored values are not a valid Hugging Face file.
    public static var stored: CustomCleanupModel? { stored(in: .standard) }
    static func stored(in defaults: UserDefaults) -> CustomCleanupModel? {
        guard let data = defaults.data(forKey: key), let model = try? JSONDecoder().decode(CustomCleanupModel.self, from: data), model.isValid else { return nil }
        return model
    }
    public static func store(_ model: CustomCleanupModel?) { store(model, in: .standard) }
    static func store(_ model: CustomCleanupModel?, in defaults: UserDefaults) {
        if let model, let data = try? JSONEncoder().encode(model) { defaults.set(data, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    public var isValid: Bool { HuggingFace.isValidRepo(repo) && HuggingFace.isValidFileName(fileName) }
    /// The repo name without its owner, for display.
    public var displayName: String { String(repo.split(separator: "/").last ?? Substring(repo)) }
    public var repoURL: URL { URL(string: "https://huggingface.co/\(repo)") ?? URL(string: "https://huggingface.co")! }
    /// Pinned to the commit the file was listed from when there is one, so a re-download gets the same bytes.
    public var downloadURL: URL? {
        guard isValid else { return nil }
        let ref = revision.flatMap { HuggingFace.isValidRevision($0) ? $0 : nil } ?? "main"
        return URL(string: "https://huggingface.co/\(repo)/resolve/\(ref)/\(fileName)")
    }
    /// Custom files live in their own folder so they can never collide with the built-in models.
    /// Deliberately independent of `revision`: saving the same repo and file again keeps the existing download,
    /// so a new revision is not fetched unless the file is missing.
    public var localURL: URL {
        ModelStorage.tidyFolder.appendingPathComponent("custom").appendingPathComponent(repo.replacingOccurrences(of: "/", with: "--") + "--" + fileName)
    }
}

public enum HuggingFace {
    public struct File: Equatable, Sendable {
        public let name: String
        public let size: Int64?
        public init(name: String, size: Int64?) { self.name = name; self.size = size }
    }
    public struct Reference: Equatable, Sendable {
        public let repo: String
        public let fileName: String?
    }

    private static let nameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    private static let hexCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    private static let reservedOwners: Set<String> = ["models", "datasets", "spaces", "docs", "blog", "api", "papers", "collections"]
    private static let hosts: Set<String> = ["huggingface.co", "www.huggingface.co", "hf.co"]

    private static func isValidComponent(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 120 && !value.hasPrefix(".") && value.unicodeScalars.allSatisfy(nameCharacters.contains)
    }
    /// `owner/name`, restricted to characters Hugging Face allows so the value is safe in a URL and a file name.
    public static func isValidRepo(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 2 && parts.allSatisfy(isValidComponent) && !reservedOwners.contains(parts[0].lowercased())
    }
    public static func isValidFileName(_ value: String) -> Bool { value.lowercased().hasSuffix(".gguf") && isValidComponent(value) }
    /// A commit hash is only safe in a URL when it is plain hex of a plausible length.
    public static func isValidRevision(_ value: String) -> Bool {
        (7...64).contains(value.count) && value.unicodeScalars.allSatisfy(hexCharacters.contains)
    }

    /// Accepts a model page, a `blob`/`resolve` file link, or a bare `owner/name`; the scheme is optional.
    public static func parse(_ input: String) -> Reference? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.lowercased().hasPrefix("http") {
            guard let url = URL(string: text), url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased(), hosts.contains(host) else { return nil }
            return reference(path: url.pathComponents.filter { $0 != "/" })
        }
        // Scheme-less: `huggingface.co/owner/name`, `hf.co/...`, or a bare `owner/name`.
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if let host = parts.first?.lowercased(), hosts.contains(host) { return reference(path: Array(parts.dropFirst())) }
        return isValidRepo(text) ? Reference(repo: text, fileName: nil) : nil
    }
    private static func reference(path parts: [String]) -> Reference? {
        guard parts.count >= 2, isValidRepo("\(parts[0])/\(parts[1])") else { return nil }
        var file: String?
        if parts.count == 5, ["blob", "resolve"].contains(parts[2]), parts[3] == "main", isValidFileName(parts[4]) { file = parts[4] }
        return Reference(repo: "\(parts[0])/\(parts[1])", fileName: file)
    }

    /// The `/api/models/<repo>` reply: the commit `sha` plus the file list.
    private struct Listing: Decodable {
        struct Sibling: Decodable {
            struct LFS: Decodable { let size: Int64? }
            let rfilename: String
            let size: Int64?
            let lfs: LFS?
        }
        let sha: String?
        let siblings: [Sibling]?
    }

    private static func listing(in data: Data) throws -> Listing {
        do { return try JSONDecoder().decode(Listing.self, from: data) }
        catch { throw CoreError.message("Hugging Face sent a reply Murmur couldn’t read. Try again in a moment.") }
    }

    /// Single-file GGUFs that can be run on their own: no vision projectors, no split shards, nothing in subfolders.
    public static func ggufFiles(in data: Data) throws -> [File] { try files(in: try listing(in: data)) }

    private static func files(in listing: Listing) throws -> [File] {
        let shard = try NSRegularExpression(pattern: "-\\d{5}-of-\\d{5}")
        return (listing.siblings ?? []).compactMap { sibling -> File? in
            let name = sibling.rfilename, lower = name.lowercased()
            guard isValidFileName(name), !lower.contains("mmproj"),
                  shard.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) == nil else { return nil }
            return File(name: name, size: sibling.lfs?.size ?? sibling.size)
        }
        .sorted { ($0.size ?? .max, $0.name) < ($1.size ?? .max, $1.name) }
    }

    /// Q4_K_M is the usual size/quality balance; otherwise the smallest file.
    public static func preferred(_ files: [File]) -> File? {
        files.first { $0.name.localizedCaseInsensitiveContains("q4_k_m") } ?? files.min { ($0.size ?? .max) < ($1.size ?? .max) }
    }

    /// The repo's GGUF files plus the commit they came from, so a download can be pinned to it.
    public static func listGGUFRepository(repo: String, session: URLSession = .shared) async throws -> (files: [File], revision: String?) {
        guard isValidRepo(repo), let url = URL(string: "https://huggingface.co/api/models/\(repo)?blobs=true") else { throw CoreError.message("That is not a valid Hugging Face model name.") }
        var request = URLRequest(url: url); request.timeoutInterval = 20
        let (data, response) = try await data(for: request, session: session)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300:
            let listing = try listing(in: data)
            guard listing.siblings != nil else { throw CoreError.message("Hugging Face didn’t list any files for \(repo). Check the link and try again.") }
            return (try files(in: listing), listing.sha.flatMap { isValidRevision($0) ? $0 : nil })
        case 401, 403: throw CoreError.message("This model is private or needs you to accept its terms on Hugging Face first, so Murmur can’t download it.")
        case 404: throw CoreError.message("Hugging Face has no model called \(repo).")
        case let code: throw CoreError.message("Hugging Face returned an error (\(code)). Try again in a moment.")
        }
    }

    /// The GGUF files alone; `listGGUFRepository` also reports the commit they came from.
    public static func listGGUFFiles(repo: String, session: URLSession = .shared) async throws -> [File] {
        try await listGGUFRepository(repo: repo, session: session).files
    }

    private static func data(for request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: request) }
        catch let error as URLError { throw networkError(error.code) }
        catch let error as NSError where error.domain == NSURLErrorDomain { throw networkError(URLError.Code(rawValue: error.code)) }
    }
    private static func networkError(_ code: URLError.Code) -> CoreError {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .cannotConnectToHost, .cannotFindHost:
            return .message("You appear to be offline. Check your connection and try again.")
        case .timedOut:
            return .message("Hugging Face took too long to answer. Try again in a moment.")
        default:
            return .message("Couldn’t reach Hugging Face. Check your connection and try again.")
        }
    }
}
