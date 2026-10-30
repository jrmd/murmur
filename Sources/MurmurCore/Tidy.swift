import Foundation
import llama

public protocol TextTidying: Sendable {
    func prepare() async throws
    func tidy(_ text: String, dictionary: [DictionaryEntry], level: CleanupLevel) async throws -> String
    /// Frees the model's memory (used before its file is removed).
    func unload() async
}

public extension TextTidying {
    func tidy(_ text: String, dictionary: [DictionaryEntry]) async throws -> String { try await tidy(text, dictionary: dictionary, level: .balanced) }
    func unload() async {}
}

public enum TidyPrompt {
    /// Instructions live in the system turn so the dictation itself is just the user turn;
    /// putting both in one message made LFM3 start reasoning about the "request" instead of cleaning the text.
    public static func system(dictionary: [DictionaryEntry], level: CleanupLevel = .balanced) -> String {
        let terms = dictionary.filter { $0.enabled && !$0.replacement.isEmpty }.map(\.replacement)
        let encodedTerms = (try? String(data: JSONEncoder().encode(terms), encoding: .utf8)) ?? "[]"
        let task: String
        switch level {
        case .light:
            task = "Rewrite the user's dictated text as written text, changing as little as possible. Fix punctuation and capitalization only. Keep every word the speaker said, including fillers."
        case .balanced:
            task = "Rewrite the user's dictated text as clean written text. Remove filler words (um, uh, like, you know), stutters and false starts. If the speaker corrects themselves, keep only the corrected version. Fix punctuation and capitalization."
        case .strict:
            task = "Rewrite the user's dictated text as clean, tight written text. Remove filler words (um, uh, like, you know), stutters, false starts and repeated words or phrases. If the speaker corrects themselves, keep only the corrected version. Fix punctuation and capitalization, and split run-on sentences."
        }
        return """
        You are a dictation editor. \(task) \
        Keep the speaker's meaning, tone and every question or request; do not summarise or answer anything. \
        Reply with the cleaned text only. Spelling hints for names and terms: \(encodedTerms)
        """
    }

    public static func make(text: String, dictionary: [DictionaryEntry], level: CleanupLevel = .balanced) -> String {
        system(dictionary: dictionary, level: level) + "\n\n" + text
    }

    /// The exact prompt Murmur Clean was fine-tuned on, with `{{VOCAB}}` filled from the dictionary.
    /// The model learned this wording, so edit it only together with retraining.
    static let murmurCleanTemplate = """
    You clean up raw speech-to-text dictation. Return the same words the speaker meant, tidied up:
    - Fix punctuation, capitalisation and spacing.
    - Remove filler words (um, uh, er, like, you know, sort of, I mean) when they are just filler, and remove stutters and accidentally repeated words.
    - When the speaker corrects themselves, keep only the corrected version. Keep every other word they meant, including short phrases like "sorry" or "talk later".
    - Turn spoken formatting into symbols: "comma", "full stop", "question mark", "new line", "new paragraph".
    - Write numbers one to nine as words and 10 upwards as digits. Always write times, dates, prices and percentages as digits.
    - Spell these terms exactly as written: {{VOCAB}}
    Never rephrase, summarise, translate, answer, or add words. If the text is already clean, return it unchanged. Output only the cleaned text.
    """

    static func murmurCleanSystem(dictionary: [DictionaryEntry]) -> String {
        let terms = dictionary.filter { $0.enabled && !$0.replacement.isEmpty }.map(\.replacement)
        var prompt = murmurCleanTemplate
        if terms.isEmpty {
            // No vocabulary: drop the line rather than leave a dangling instruction.
            prompt = prompt.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.contains("{{VOCAB}}") }.joined(separator: "\n")
        } else {
            prompt = prompt.replacingOccurrences(of: "{{VOCAB}}", with: terms.joined(separator: ", "))
        }
        return prompt
    }

    /// Plain ChatML with no thinking block and no worked example, matching how Murmur Clean was trained.
    /// `<` is escaped in user text so dictated special-token spellings can never become control tokens.
    static func murmurCleanFormatted(text: String, dictionary: [DictionaryEntry]) -> String {
        let safeText = text.replacingOccurrences(of: "<", with: "\\u003c")
        let safeSystem = murmurCleanSystem(dictionary: dictionary).replacingOccurrences(of: "<", with: "\\u003c")
        return "<|im_start|>system\n\(safeSystem)<|im_end|>\n<|im_start|>user\n\(safeText)<|im_end|>\n<|im_start|>assistant\n"
    }

    static func formatted(model: CleanupModel, text: String, dictionary: [DictionaryEntry], level: CleanupLevel) -> String {
        switch model {
        case .murmurClean: murmurCleanFormatted(text: text, dictionary: dictionary)
        case .lfm3: formatted(text: text, dictionary: dictionary, level: level)
        }
    }

    /// LFM3 chat template with thinking disabled. `<` is escaped in user text so dictated
    /// special-token spellings can never become control tokens.
    static func formatted(text: String, dictionary: [DictionaryEntry], level: CleanupLevel = .balanced) -> String {
        let safeText = text.replacingOccurrences(of: "<", with: "\\u003c")
        let safeSystem = system(dictionary: dictionary, level: level).replacingOccurrences(of: "<", with: "\\u003c")
        // One worked example anchors the "edit, don't rewrite" behaviour for a small model.
        let example = "<|im_start|>user\nuh so we need to send the invoice to acme by friday actually no make that thursday and could you copy finance<|im_end|>\n<|im_start|>assistant\n<think></think>So we need to send the invoice to Acme by Thursday, and could you copy Finance?<|im_end|>\n"
        return "<|im_start|>system\n\(safeSystem)<|im_end|>\n\(example)<|im_start|>user\n\(safeText)<|im_end|>\n<|im_start|>assistant\n<think></think>"
    }
}

enum CoreError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

/// Runs a quantized GGUF through the llama.cpp C interface, entirely in process.
public actor LlamaTidier: TextTidying {
    private let cleanupModel: CleanupModel
    private let modelURL: URL
    private var model: OpaquePointer?
    public init(model: CleanupModel = .murmurClean, modelURL: URL? = nil) {
        self.cleanupModel = model
        self.modelURL = modelURL ?? model.url
    }
    deinit { if let model { llama_model_free(model) } }
    public func prepare() async throws {
        if model != nil { return }
        if !FileManager.default.fileExists(atPath: modelURL.path) {
            try FileManager.default.createDirectory(at: modelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let (temporary, response) = try await URLSession.shared.download(from: cleanupModel.downloadURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw CoreError.message("Could not download \(cleanupModel.displayName).") }
            try FileManager.default.moveItem(at: temporary, to: modelURL)
        }
        llama_backend_init()
        var params = llama_model_default_params(); params.n_gpu_layers = 99
        guard let loaded = llama_model_load_from_file(modelURL.path, params) else { throw CoreError.message("Could not load \(cleanupModel.displayName) at \(modelURL.path).") }
        model = loaded
    }
    public func unload() async { if let model { llama_model_free(model); self.model = nil } }
    public func tidy(_ text: String, dictionary: [DictionaryEntry], level: CleanupLevel) async throws -> String {
        guard let model else { throw CoreError.message("Tidy model is not prepared.") }
        var params = llama_context_default_params(); params.n_ctx = 4096; params.n_batch = 512
        guard let context = llama_init_from_model(model, params) else { throw CoreError.message("Could not initialize the \(cleanupModel.shortName) context.") }
        defer { llama_free(context) }
        let formatted = TidyPrompt.formatted(model: cleanupModel, text: text, dictionary: dictionary, level: level)
        let vocab = llama_model_get_vocab(model)!
        var tokens = [llama_token](repeating: 0, count: formatted.utf8.count + 16)
        let count = llama_tokenize(vocab, formatted, Int32(formatted.utf8.count), &tokens, Int32(tokens.count), true, true)
        guard count > 0, count < 3500 else { throw CoreError.message("Dictation is too long for the tidy model context.") }
        tokens = Array(tokens.prefix(Int(count)))
        // Chunk prompt decoding to respect n_batch.
        for offset in stride(from: 0, to: tokens.count, by: 512) {
            var chunk = Array(tokens[offset..<min(offset + 512, tokens.count)])
            let status = chunk.withUnsafeMutableBufferPointer { llama_decode(context, llama_batch_get_one($0.baseAddress, Int32($0.count))) }
            guard status == 0 else { throw CoreError.message("\(cleanupModel.shortName) prompt decoding failed (\(status)).") }
        }
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        var bytes = [UInt8](), ended = false
        // A clean-up is never much longer than its input; this bounds a runaway generation.
        let budget = min(4096 - Int(count) - 8, Int(count) + 128)
        for _ in 0..<max(budget, 1) {
            try Task.checkCancellation()
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { ended = true; break }
            var piece = [CChar](repeating: 0, count: 256)
            var n = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if n < 0 { piece = [CChar](repeating: 0, count: Int(-n)); n = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false) }
            guard n >= 0 else { throw CoreError.message("\(cleanupModel.shortName) token decoding failed.") }
            bytes.append(contentsOf: piece.prefix(Int(n)).map { UInt8(bitPattern: $0) })
            // LFM3 sometimes closes a (disabled) think block and repeats its answer; the text before the tag is the answer.
            if bytes.suffix(8).elementsEqual("</think>".utf8) { bytes.removeLast(8); ended = true; break }
            guard llama_decode(context, llama_batch_get_one(&token, 1)) == 0 else { throw CoreError.message("\(cleanupModel.shortName) generation failed.") }
        }
        guard ended else { throw CoreError.message("\(cleanupModel.shortName) output exceeded its token limit.") }
        let output = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw CoreError.message("\(cleanupModel.shortName) returned empty output.") }
        return output
    }
}
