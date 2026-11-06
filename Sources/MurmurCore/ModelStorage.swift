import Foundation
import FluidAudio

/// Speech-recognition models Murmur can run, all Parakeet TDT 0.6B variants managed by FluidAudio.
public enum SpeechModel: String, CaseIterable, Identifiable, Sendable {
    case parakeetV3, parakeetV2
    /// moondream's post-training of v3: same architecture and languages, more accurate.
    case parakeetUltra
    public var id: String { rawValue }
    var asrVersion: AsrModelVersion {
        switch self {
        case .parakeetV3: .v3
        case .parakeetV2: .v2
        case .parakeetUltra: .ultra
        }
    }
    public var shortName: String {
        switch self {
        case .parakeetV3: "Parakeet v3"
        case .parakeetV2: "Parakeet v2"
        case .parakeetUltra: "Parakeet Ultra"
        }
    }
    public var displayName: String {
        switch self {
        case .parakeetV3: "Parakeet TDT 0.6B v3"
        case .parakeetV2: "Parakeet TDT 0.6B v2"
        case .parakeetUltra: "Parakeet Ultra"
        }
    }
    public var detail: String {
        switch self {
        case .parakeetV3: "NVIDIA · 25 European languages"
        case .parakeetV2: "NVIDIA · English only"
        case .parakeetUltra: "moondream · post-trained v3 · 25 languages"
        }
    }
    public var approximateBytes: Int64 { self == .parakeetUltra ? 630_000_000 : 461_000_000 }
    public var directory: URL { AsrModels.defaultCacheDirectory(for: asrVersion) }
    public var isInstalled: Bool { AsrModels.modelsExist(at: directory, version: asrVersion) }
    public var installedBytes: Int64 { ModelStorage.bytes(at: directory) }
}

/// Clean-up models Murmur can run, all as GGUF files through llama.cpp.
public enum CleanupModel: String, CaseIterable, Identifiable, Sendable {
    /// Murmur's own LoRA fine-tune of LFM2.5-350M, trained on one fixed prompt.
    case murmurClean
    /// Liquid AI's general-purpose LFM3 1.7B, steered by prompt and strictness level.
    case lfm3
    /// A GGUF the user picked from Hugging Face, run with their own system prompt (see `CustomCleanupModel`).
    case custom
    public var id: String { rawValue }
    /// The models Murmur ships a download for; `custom` is configured by the user.
    public static var builtIn: [CleanupModel] { [.murmurClean, .lfm3] }
    private var customModel: CustomCleanupModel? { CustomCleanupModel.stored }
    public var displayName: String {
        switch self {
        case .murmurClean: "Murmur Clean 350M"
        case .lfm3: "LFM3 1.7B"
        case .custom: customModel?.displayName ?? "Custom model"
        }
    }
    public var shortName: String {
        switch self {
        case .murmurClean: "Murmur Clean"
        case .lfm3: "LFM3"
        case .custom: "Custom"
        }
    }
    public var detail: String {
        switch self {
        case .murmurClean: "Bonus Objective · trained for dictation · English"
        case .lfm3: "Liquid AI · general purpose · runs on your Mac"
        case .custom: customModel.map { "\($0.repo) · \($0.fileName)" } ?? "Any GGUF model from Hugging Face"
        }
    }
    public var summary: String {
        switch self {
        case .murmurClean: "Small, fast and trained for exactly this job. English only."
        case .lfm3: "Larger and general purpose, with adjustable strictness."
        case .custom: "Your own model and prompt. Quality and languages depend on the model you choose."
        }
    }
    /// Only the general-purpose model is steered by `CleanupLevel`; Murmur Clean always runs the prompt it was trained on
    /// and a custom model runs the prompt the user wrote.
    public var supportsLevels: Bool { self == .lfm3 }
    public var fileName: String {
        switch self {
        case .murmurClean: "murmur-clean-q8_0.gguf"
        case .lfm3: "LFM3-1.7B-Q4_K_M.gguf"
        case .custom: customModel?.fileName ?? "custom.gguf"
        }
    }
    /// The Hugging Face commit the built-in file is pinned to, so a repo update cannot silently change what Murmur
    /// downloads. A custom model follows `main`, because the user picked the file themselves.
    public var revision: String? {
        switch self {
        case .murmurClean: "bad305e9d2373f706e048e250b75f7fb471692fb"
        case .lfm3: "cd0c74c575b5c416f3011b5b4c298077f26ca8c2"
        case .custom: nil
        }
    }
    /// SHA-256 of the pinned file, checked after download. nil for a custom model, whose file Murmur cannot vouch for.
    public var sha256: String? {
        switch self {
        case .murmurClean: "5254afa6842453930b7e9be384399d3ffc85d289b77b8b08a8ab2ed8d3943fd9"
        case .lfm3: "3793e1e6e2266919d6e015287221b41100175a98eddaba92e111aed3b05c93c4"
        case .custom: nil
        }
    }
    public var downloadURL: URL {
        switch self {
        case .murmurClean: URL(string: "https://huggingface.co/bonusobjective/murmur-clean-350m/resolve/\(revision ?? "main")/murmur-clean-q8_0.gguf")!
        case .lfm3: URL(string: "https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF/resolve/\(revision ?? "main")/LFM3-1.7B-Q4_K_M.gguf")!
        case .custom: customModel?.downloadURL ?? URL(string: "https://huggingface.co")!
        }
    }
    /// The exact size of the pinned file, used for download progress before the server answers.
    public var approximateBytes: Int64 {
        switch self {
        case .murmurClean: 379_220_000
        case .lfm3: 1_099_627_808
        case .custom: customModel?.sizeBytes ?? 0
        }
    }
    public var url: URL { self == .custom ? (customModel?.localURL ?? ModelStorage.tidyFolder.appendingPathComponent("custom/none.gguf")) : ModelStorage.tidyFolder.appendingPathComponent(fileName) }
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: url.path) }
    public var installedBytes: Int64 { ModelStorage.bytes(at: url) }
    public var licenceURL: URL {
        switch self {
        case .murmurClean: URL(string: "https://huggingface.co/bonusobjective/murmur-clean-350m/blob/main/LICENSE")!
        case .lfm3: URL(string: "https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF/blob/main/LICENSE")!
        case .custom: customModel?.repoURL ?? URL(string: "https://huggingface.co")!
        }
    }
}

/// How much the LFM3 clean-up pass is allowed to change (Murmur Clean ignores it).
public enum CleanupLevel: String, CaseIterable, Identifiable, Sendable {
    case light, balanced, strict
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
    public var summary: String {
        switch self {
        case .light: "Light fixes punctuation and capitals only. Every word you said stays."
        case .balanced: "Balanced fixes punctuation and fillers, but never rewords."
        case .strict: "Strict also drops repeats and resolves corrections, and tightens run-ons."
        }
    }
}

public enum ModelStorage {
    public static var tidyFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Murmur/models")
    }
    /// Parent folder FluidAudio keeps the Parakeet models in.
    public static var speechFolder: URL { SpeechModel.parakeetV3.directory.deletingLastPathComponent() }

    public static func bytes(at url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return (try? url.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize).flatMap { Int64($0) } ?? 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    public static var totalBytesUsed: Int64 {
        SpeechModel.allCases.reduce(0) { $0 + $1.installedBytes } + bytes(at: tidyFolder)
    }

    public static func remove(_ model: SpeechModel) throws {
        if FileManager.default.fileExists(atPath: model.directory.path) { try FileManager.default.removeItem(at: model.directory) }
    }

    public static func remove(_ model: CleanupModel) throws {
        if model.isInstalled { try FileManager.default.removeItem(at: model.url) }
        let part = ModelDownloader.partURL(for: model.url)
        if FileManager.default.fileExists(atPath: part.path) { try FileManager.default.removeItem(at: part) }
        removeStalePartials()
    }

    /// Deletes `.part` files left by downloads that were abandoned more than `age` ago, so a cancelled download does
    /// not sit in Application Support forever. A recent one is kept, because it is what the next attempt resumes from.
    @discardableResult
    public static func removeStalePartials(olderThan age: TimeInterval = 7 * 24 * 60 * 60, in folder: URL = tidyFolder) -> Int {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        let cutoff = Date().addingTimeInterval(-age)
        var removed = 0
        for case let file as URL in files where file.pathExtension == "part" {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified < cutoff else { continue }
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }
}
