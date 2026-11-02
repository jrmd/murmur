import Foundation

/// A clean-up model the user pointed Murmur at: one GGUF file from a Hugging Face repo, plus the system prompt to run it with.
public struct CustomCleanupModel: Codable, Equatable, Sendable {
    public var repo: String
    public var fileName: String
    public var systemPrompt: String
    public var sizeBytes: Int64?

    /// Replaced with the dictionary's spellings; a line containing it is dropped when the dictionary is empty.
    public static let vocabularyPlaceholder = "{{VOCAB}}"
    public static let defaultPrompt = """
    You are a dictation editor. Rewrite the user's dictated text as clean written text, in the same language it was spoken in. Never translate. \
    Remove filler words and stutters, and if the speaker corrects themselves keep only the corrected version. Fix punctuation and capitalisation. \
    Keep the speaker's meaning, tone and every question or request; do not summarise or answer anything. Reply with the cleaned text only.
    Spelling hints for names and terms: {{VOCAB}}
    """

    public init(repo: String, fileName: String, systemPrompt: String = CustomCleanupModel.defaultPrompt, sizeBytes: Int64? = nil) {
        self.repo = repo; self.fileName = fileName; self.systemPrompt = systemPrompt; self.sizeBytes = sizeBytes
    }

    private static let key = "customCleanupModel"
    /// The saved choice, or nil when none was made or the stored values are not a valid Hugging Face file.
    public static var stored: CustomCleanupModel? {
        guard let data = UserDefaults.standard.data(forKey: key), let model = try? JSONDecoder().decode(CustomCleanupModel.self, from: data), model.isValid else { return nil }
        return model
    }
    public static func store(_ model: CustomCleanupModel?) {
        if let model, let data = try? JSONEncoder().encode(model) { UserDefaults.standard.set(data, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    public var isValid: Bool { HuggingFace.isValidRepo(repo) && HuggingFace.isValidFileName(fileName) }
    /// The repo name without its owner, for display.
    public var displayName: String { String(repo.split(separator: "/").last ?? Substring(repo)) }
    public var repoURL: URL { URL(string: "https://huggingface.co/\(repo)") ?? URL(string: "https://huggingface.co")! }
    public var downloadURL: URL? { isValid ? URL(string: "https://huggingface.co/\(repo)/resolve/main/\(fileName)") : nil }
    /// Custom files live in their own folder so they can never collide with the built-in models.
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
    private static let reservedOwners: Set<String> = ["models", "datasets", "spaces", "docs", "blog", "api", "papers", "collections"]

    private static func isValidComponent(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 120 && !value.hasPrefix(".") && value.unicodeScalars.allSatisfy(nameCharacters.contains)
    }
    /// `owner/name`, restricted to characters Hugging Face allows so the value is safe in a URL and a file name.
    public static func isValidRepo(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 2 && parts.allSatisfy(isValidComponent) && !reservedOwners.contains(parts[0].lowercased())
    }
    public static func isValidFileName(_ value: String) -> Bool { value.lowercased().hasSuffix(".gguf") && isValidComponent(value) }

    /// Accepts a model page, a `blob`/`resolve` file link, or a bare `owner/name`.
    public static func parse(_ input: String) -> Reference? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix("http") else { return isValidRepo(text) ? Reference(repo: text, fileName: nil) : nil }
        guard let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), host == "huggingface.co" || host == "www.huggingface.co" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, isValidRepo("\(parts[0])/\(parts[1])") else { return nil }
        var file: String?
        if parts.count == 5, ["blob", "resolve"].contains(parts[2]), parts[3] == "main", isValidFileName(parts[4]) { file = parts[4] }
        return Reference(repo: "\(parts[0])/\(parts[1])", fileName: file)
    }

    /// Single-file GGUFs that can be run on their own: no vision projectors, no split shards, nothing in subfolders.
    public static func ggufFiles(in data: Data) throws -> [File] {
        struct Listing: Decodable {
            struct Sibling: Decodable { let rfilename: String; let size: Int64? }
            let siblings: [Sibling]?
        }
        let listing = try JSONDecoder().decode(Listing.self, from: data)
        let shard = try NSRegularExpression(pattern: "-\\d{5}-of-\\d{5}")
        return (listing.siblings ?? []).compactMap { sibling -> File? in
            let name = sibling.rfilename, lower = name.lowercased()
            guard isValidFileName(name), !lower.contains("mmproj"),
                  shard.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) == nil else { return nil }
            return File(name: name, size: sibling.size)
        }
        .sorted { ($0.size ?? .max, $0.name) < ($1.size ?? .max, $1.name) }
    }

    /// Q4_K_M is the usual size/quality balance; otherwise the smallest file.
    public static func preferred(_ files: [File]) -> File? {
        files.first { $0.name.localizedCaseInsensitiveContains("q4_k_m") } ?? files.min { ($0.size ?? .max) < ($1.size ?? .max) }
    }

    public static func listGGUFFiles(repo: String) async throws -> [File] {
        guard isValidRepo(repo), let url = URL(string: "https://huggingface.co/api/models/\(repo)?blobs=true") else { throw CoreError.message("That is not a valid Hugging Face model name.") }
        var request = URLRequest(url: url); request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: return try ggufFiles(in: data)
        case 401, 403: throw CoreError.message("This model is private or needs you to accept its terms on Hugging Face first, so Murmur can’t download it.")
        case 404: throw CoreError.message("Hugging Face has no model called \(repo).")
        case let code: throw CoreError.message("Hugging Face returned an error (\(code)). Try again in a moment.")
        }
    }
}
