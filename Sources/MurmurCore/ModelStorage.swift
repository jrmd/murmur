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

/// Clean-up models Murmur can run, both as GGUF files through llama.cpp.
public enum CleanupModel: String, CaseIterable, Identifiable, Sendable {
    /// Murmur's own LoRA fine-tune of LFM2.5-350M, trained on one fixed prompt.
    case murmurClean
    /// Liquid AI's general-purpose LFM3 1.7B, steered by prompt and strictness level.
    case lfm3
    public var id: String { rawValue }
    public var displayName: String { self == .murmurClean ? "Murmur Clean 350M" : "LFM3 1.7B" }
    public var shortName: String { self == .murmurClean ? "Murmur Clean" : "LFM3" }
    public var detail: String {
        switch self {
        case .murmurClean: "Bonus Objective · trained for dictation · English"
        case .lfm3: "Liquid AI · general purpose · runs on your Mac"
        }
    }
    public var summary: String {
        switch self {
        case .murmurClean: "Small, fast and trained for exactly this job. English only."
        case .lfm3: "Larger and general purpose, with adjustable strictness."
        }
    }
    /// Only the general-purpose model is steered by `CleanupLevel`; Murmur Clean always runs the prompt it was trained on.
    public var supportsLevels: Bool { self == .lfm3 }
    public var fileName: String { self == .murmurClean ? "murmur-clean-q8_0.gguf" : "LFM3-1.7B-Q4_K_M.gguf" }
    public var downloadURL: URL {
        switch self {
        case .murmurClean: URL(string: "https://huggingface.co/bonusobjective/murmur-clean-350m/resolve/main/murmur-clean-q8_0.gguf")!
        case .lfm3: URL(string: "https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF/resolve/main/LFM3-1.7B-Q4_K_M.gguf")!
        }
    }
    public var approximateBytes: Int64 { self == .murmurClean ? 379_220_000 : 1_099_627_808 }
    public var url: URL { ModelStorage.tidyFolder.appendingPathComponent(fileName) }
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: url.path) }
    public var installedBytes: Int64 { ModelStorage.bytes(at: url) }
    public var licenceURL: URL {
        switch self {
        case .murmurClean: URL(string: "https://huggingface.co/bonusobjective/murmur-clean-350m/blob/main/LICENSE")!
        case .lfm3: URL(string: "https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF/blob/main/LICENSE")!
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
    }
}
