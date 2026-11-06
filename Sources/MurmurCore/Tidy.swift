import Foundation
import llama

public protocol TextTidying: Sendable {
    func prepare() async throws
    /// The same as `prepare()`, reporting download progress as a fraction from 0 to 1.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    func tidy(_ text: String, dictionary: [DictionaryEntry], level: CleanupLevel) async throws -> String
    /// Frees the model's memory (used before its file is removed).
    func unload() async
}

public extension TextTidying {
    /// A tidier only has to implement one of the two `prepare` methods; the other forwards to it.
    func prepare() async throws { try await prepare(progress: { _ in }) }
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws { try await prepare() }
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
        substitutingVocabulary(in: murmurCleanTemplate, dictionary: dictionary)
    }

    /// Fills `{{VOCAB}}` from the enabled dictionary entries. With no vocabulary the line is dropped
    /// rather than left as a dangling instruction.
    static func substitutingVocabulary(in template: String, dictionary: [DictionaryEntry]) -> String {
        let placeholder = CustomCleanupModel.vocabularyPlaceholder
        let terms = dictionary.filter { $0.enabled && !$0.replacement.isEmpty }.map(\.replacement)
        guard !terms.isEmpty else {
            return template.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.contains(placeholder) }.joined(separator: "\n")
        }
        return template.replacingOccurrences(of: placeholder, with: terms.joined(separator: ", "))
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
        case .custom: customFormatted(text: text, dictionary: dictionary, template: nil)
        }
    }

    /// `<` is escaped so dictated special-token spellings can never become control tokens.
    static func escapingControlTokens(_ text: String) -> String { text.replacingOccurrences(of: "<", with: "\\u003c") }

    static func chatML(system: String, user: String) -> String {
        "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
    }

    /// Renders system + user through a model's own chat template. nil when llama.cpp does not recognise the template
    /// (it supports a fixed list of formats, not arbitrary Jinja), so callers can fall back to ChatML.
    static func applyChatTemplate(_ template: String, system: String, user: String) -> String? {
        system.withCString { systemContent in
            user.withCString { userContent in
                "system".withCString { systemRole in
                    "user".withCString { userRole in
                        let messages = [llama_chat_message(role: systemRole, content: systemContent), llama_chat_message(role: userRole, content: userContent)]
                        var capacity = 2 * (system.utf8.count + user.utf8.count) + 512
                        for _ in 0..<2 {
                            var buffer = [CChar](repeating: 0, count: capacity)
                            let needed = llama_chat_apply_template(template, messages, messages.count, true, &buffer, Int32(capacity))
                            if needed < 0 { return nil }
                            if Int(needed) > capacity { capacity = Int(needed) + 1; continue }
                            return String(decoding: buffer.prefix(Int(needed)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        }
                        return nil
                    }
                }
            }
        }
    }

    /// The user's prompt in the model's own chat format. Thinking-capable templates get an empty think block, as with
    /// Qwen3's non-thinking mode, so the model answers straight away.
    static func customFormatted(text: String, dictionary: [DictionaryEntry], template: String?) -> String {
        let configured = CustomCleanupModel.stored?.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = configured.isEmpty ? CustomCleanupModel.defaultPrompt : configured
        let system = escapingControlTokens(substitutingVocabulary(in: prompt, dictionary: dictionary))
        let user = escapingControlTokens(text)
        var formatted = template.flatMap { applyChatTemplate($0, system: system, user: user) } ?? chatML(system: system, user: user)
        if template?.contains("<think>") == true { formatted += "<think>\n\n</think>\n\n" }
        return formatted
    }

    /// Drops a leading `<think>…</think>` block that a reasoning model emitted before its answer.
    static func strippingThinking(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<think>"), let end = trimmed.range(of: "</think>") else { return trimmed }
        return String(trimmed[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
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
    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        if model != nil { return }
        if cleanupModel == .custom, CustomCleanupModel.stored == nil { throw CoreError.message("Choose a custom clean-up model in Settings first.") }
        if !FileManager.default.fileExists(atPath: modelURL.path) {
            let expected = cleanupModel.approximateBytes
            let downloader = ModelDownloader(expectedBytes: expected > 0 ? expected : nil)
            try await downloader.download(from: cleanupModel.downloadURL, to: modelURL, expectedSHA256: cleanupModel.sha256, progress: progress)
        }
        llama_backend_init()
        var params = llama_model_default_params(); params.n_gpu_layers = 99
        guard let loaded = llama_model_load_from_file(modelURL.path, params) else { throw CoreError.message("Could not load \(cleanupModel.displayName) at \(modelURL.path).") }
        model = loaded
    }
    /// GGUF files start with the ASCII magic "GGUF"; this catches an HTML error page saved in its place.
    private static func isGGUF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("GGUF".utf8)
    }
    public func unload() async { if let model { llama_model_free(model); self.model = nil } }
    public func tidy(_ text: String, dictionary: [DictionaryEntry], level: CleanupLevel) async throws -> String {
        guard let model else { throw CoreError.message("Tidy model is not prepared.") }
        var params = llama_context_default_params(); params.n_ctx = 4096; params.n_batch = 512
        guard let context = llama_init_from_model(model, params) else { throw CoreError.message("Could not initialize the \(cleanupModel.shortName) context.") }
        defer { llama_free(context) }
        let formatted: String
        if cleanupModel == .custom {
            formatted = TidyPrompt.customFormatted(text: text, dictionary: dictionary, template: llama_model_chat_template(model, nil).map { String(cString: $0) })
        } else {
            formatted = TidyPrompt.formatted(model: cleanupModel, text: text, dictionary: dictionary, level: level)
        }
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
            if cleanupModel != .custom, bytes.suffix(8).elementsEqual("</think>".utf8) { bytes.removeLast(8); ended = true; break }
            guard llama_decode(context, llama_batch_get_one(&token, 1)) == 0 else { throw CoreError.message("\(cleanupModel.shortName) generation failed.") }
        }
        guard ended else { throw CoreError.message("\(cleanupModel.shortName) output exceeded its token limit.") }
        var output = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanupModel == .custom { output = TidyPrompt.strippingThinking(output) }
        guard !output.isEmpty else { throw CoreError.message("\(cleanupModel.shortName) returned empty output.") }
        return output
    }
}
