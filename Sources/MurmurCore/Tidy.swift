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
    /// A slice of the prompt and whether llama.cpp may read control tokens inside it. Only the template scaffolding is
    /// parsed as special tokens, so a dictated `<|im_end|>` stays text instead of ending the turn.
    struct Segment: Equatable {
        let text: String
        let parseSpecial: Bool
    }

    /// One piece of a long dictation, split so it fits the model's context on its own.
    struct Chunk: Equatable {
        let text: String
        /// The split fell on a paragraph break, so the cleaned pieces should be joined with one.
        var endsParagraph: Bool
    }

    /// The context a clean-up runs in and the budgets derived from it, kept in one place so the prompt limit, the chunk
    /// size and the generation budget can never disagree.
    enum Limits {
        /// Context window for every clean-up run.
        static let nContext: Int32 = 4096
        /// Prompt tokens one chunk may use, including the system prompt and chat scaffolding.
        static let maxPromptTokens = 1200
        /// Most tokens one clean-up may generate; a rewrite is never much longer than its input.
        static let outputReserve = 1536
        /// Prompt decoding is chunked to respect n_batch.
        static let batchSize = 512
        /// Conservative characters per token, so a chunk sized in characters stays inside its token budget.
        static let charactersPerToken = 3
        /// Smallest prompt budget worth running; below this the model has no room to work.
        static let minPromptTokens = 256

        /// Tokens one clean-up may generate: enough to rewrite its chunk, never more than the context allows.
        static func outputBudget(promptTokens: Int) -> Int {
            max(1, min(outputReserve, promptTokens + 256, Int(nContext) - promptTokens - 8))
        }
    }

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
    static func murmurCleanSegments(text: String, dictionary: [DictionaryEntry]) -> [Segment] {
        [
            Segment(text: "<|im_start|>system\n", parseSpecial: true),
            Segment(text: murmurCleanSystem(dictionary: dictionary), parseSpecial: false),
            Segment(text: "<|im_end|>\n<|im_start|>user\n", parseSpecial: true),
            Segment(text: text, parseSpecial: false),
            Segment(text: "<|im_end|>\n<|im_start|>assistant\n", parseSpecial: true),
        ]
    }

    static func murmurCleanFormatted(text: String, dictionary: [DictionaryEntry]) -> String {
        joined(murmurCleanSegments(text: text, dictionary: dictionary))
    }

    static func segments(model: CleanupModel, text: String, dictionary: [DictionaryEntry], level: CleanupLevel) -> [Segment] {
        switch model {
        case .murmurClean: murmurCleanSegments(text: text, dictionary: dictionary)
        case .lfm3: segments(text: text, dictionary: dictionary, level: level)
        case .custom: customSegments(text: text, dictionary: dictionary, template: nil)
        }
    }

    static func formatted(model: CleanupModel, text: String, dictionary: [DictionaryEntry], level: CleanupLevel) -> String {
        joined(segments(model: model, text: text, dictionary: dictionary, level: level))
    }

    static func joined(_ segments: [Segment]) -> String { segments.map(\.text).joined() }

    static func chatMLSegments(system: String, user: String, suffix: String = "") -> [Segment] {
        [
            Segment(text: "<|im_start|>system\n", parseSpecial: true),
            Segment(text: system, parseSpecial: false),
            Segment(text: "<|im_end|>\n<|im_start|>user\n", parseSpecial: true),
            Segment(text: user, parseSpecial: false),
            Segment(text: "<|im_end|>\n<|im_start|>assistant\n" + suffix, parseSpecial: true),
        ]
    }

    static func chatML(system: String, user: String) -> String { joined(chatMLSegments(system: system, user: user)) }

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
    static func customSegments(text: String, dictionary: [DictionaryEntry], template: String?) -> [Segment] {
        let configured = CustomCleanupModel.stored?.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = configured.isEmpty ? CustomCleanupModel.defaultPrompt : configured
        let system = substitutingVocabulary(in: prompt, dictionary: dictionary)
        let suffix = template?.contains("<think>") == true ? "<think>\n\n</think>\n\n" : ""
        // Render the template around a marker so the dictated text can be cut back out as its own segment.
        let marker = "\u{E000}user\u{E000}"
        let rendered = template.flatMap { applyChatTemplate($0, system: system, user: marker) } ?? chatML(system: system, user: marker)
        guard let range = rendered.range(of: marker) else { return chatMLSegments(system: system, user: text, suffix: suffix) }
        return [
            Segment(text: String(rendered[..<range.lowerBound]), parseSpecial: true),
            Segment(text: text, parseSpecial: false),
            Segment(text: String(rendered[range.upperBound...]) + suffix, parseSpecial: true),
        ]
    }

    static func customFormatted(text: String, dictionary: [DictionaryEntry], template: String?) -> String {
        joined(customSegments(text: text, dictionary: dictionary, template: template))
    }

    /// Drops a leading `<think>…</think>` block that a reasoning model emitted before its answer.
    static func strippingThinking(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<think>"), let end = trimmed.range(of: "</think>") else { return trimmed }
        return String(trimmed[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// LFM3 sometimes answers and then keeps talking: a fresh paragraph of reasoning, or a parenthetical aside about
    /// its own edit. A cleanup is one block of prose, so the answer ends where that aside begins.
    static func trimmingCommentary(_ text: String) -> String {
        var end = text.range(of: "\n\n")?.lowerBound ?? text.endIndex
        var search = text.startIndex
        while let aside = text.range(of: " (", range: search..<end) {
            if commentaryOpeners.contains(where: { text[aside.upperBound...].lowercased().hasPrefix($0) }) { end = aside.lowerBound; break }
            search = aside.upperBound
        }
        return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The words LFM3 opens a parenthetical aside with when it starts commenting on its own answer.
    private static let commentaryOpeners = ["wait", "or:", "note", "actually", "hmm", "let me", "i mean", "the user"]

    /// True when the text ends in a phrase it has already repeated: how a small model loops instead of stopping.
    static func isRepeating(_ text: String, window: Int = 24, repeats: Int = 3) -> Bool {
        let characters = Array(text)
        guard characters.count >= window * repeats else { return false }
        let tail = String(characters.suffix(window))
        var count = 0, index = 0
        while index + window <= characters.count {
            if String(characters[index..<(index + window)]) == tail { count += 1; index += window } else { index += 1 }
        }
        return count >= repeats
    }

    /// Whether a run that hit the token limit still produced a finished cleanup rather than a half-written thought.
    static func isCompleteCleanup(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?".contains(last)
    }

    /// LFM3 chat template with thinking disabled. The worked example sits in the system turn: as a fake
    /// user/assistant exchange the model read it as conversation history and kept talking after its answer.
    static func segments(text: String, dictionary: [DictionaryEntry], level: CleanupLevel = .balanced) -> [Segment] {
        // One worked example anchors the "edit, don't rewrite" behaviour for a small model.
        let example = "\n\nExample dictation: uh so we need to send the invoice to acme by friday actually no make that thursday and could you copy finance\nExample cleaned text: So we need to send the invoice to Acme by Thursday, and could you copy Finance?"
        return [
            Segment(text: "<|im_start|>system\n", parseSpecial: true),
            Segment(text: system(dictionary: dictionary, level: level) + example, parseSpecial: false),
            Segment(text: "<|im_end|>\n<|im_start|>user\n", parseSpecial: true),
            Segment(text: text, parseSpecial: false),
            Segment(text: "<|im_end|>\n<|im_start|>assistant\n<think></think>", parseSpecial: true),
        ]
    }

    static func formatted(text: String, dictionary: [DictionaryEntry], level: CleanupLevel = .balanced) -> String {
        joined(segments(text: text, dictionary: dictionary, level: level))
    }

    /// Splits a dictation into pieces that each fit the model's context, preferring paragraph breaks, then sentence
    /// ends, then clause marks, then word breaks, and only cutting mid-word when a single word is longer than the limit.
    static func chunks(of text: String, maxCharacters: Int) -> [Chunk] {
        let limit = max(maxCharacters, 1)
        let characters = Array(text)
        guard characters.count > limit else { return text.isEmpty ? [] : [Chunk(text: text, endsParagraph: false)] }
        var chunks: [Chunk] = []
        var start = 0
        while start < characters.count {
            var end = min(start + limit, characters.count)
            if end < characters.count { end = splitPoint(in: characters, from: start, to: end) }
            let piece = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            var scan = end, paragraph = false
            while scan < characters.count, characters[scan].isWhitespace {
                if characters[scan] == "\n" { paragraph = true }
                scan += 1
            }
            if !piece.isEmpty { chunks.append(Chunk(text: piece, endsParagraph: paragraph)) }
            start = scan
        }
        return chunks
    }

    /// The best place to cut at or before `end`: a paragraph break, else a sentence end, else a clause mark, else a space.
    /// Nothing before the halfway point counts, so a stray early break cannot leave a chunk almost empty.
    private static func splitPoint(in characters: [Character], from start: Int, to end: Int) -> Int {
        let floor = max(start + 1, start + (end - start) / 2)
        for index in stride(from: end, through: floor, by: -1) where characters[index] == "\n" { return index }
        for marks in [".!?…", ",;:—–"] {
            for index in stride(from: end, through: floor, by: -1) where marks.contains(characters[index - 1]) && characters[index].isWhitespace { return index }
        }
        for index in stride(from: end, through: floor, by: -1) where characters[index].isWhitespace { return index }
        return end
    }

    /// Joins cleaned chunks with a single space, or a paragraph break where the split fell on one.
    static func joining(_ cleaned: [String], chunks: [Chunk]) -> String {
        var output = ""
        for (index, part) in cleaned.enumerated() {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !output.isEmpty {
                let paragraph = index > 0 && chunks.indices.contains(index - 1) && chunks[index - 1].endsParagraph
                output += paragraph ? "\n\n" : " "
            }
            output += trimmed
        }
        return output
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
    /// One context per loaded model, reused across dictations; its memory is cleared before every run.
    private var context: OpaquePointer?
    public init(model: CleanupModel = .murmurClean, modelURL: URL? = nil) {
        self.cleanupModel = model
        self.modelURL = modelURL ?? model.url
    }
    /// `llama_backend_init()` is idempotent and runs in `prepare()`; `llama_backend_free()` is process-wide (MPI only),
    /// so it is deliberately not called here.
    deinit {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
    }
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
    public func unload() async {
        if let context { llama_free(context); self.context = nil }
        if let model { llama_model_free(model); self.model = nil }
    }
    public func tidy(_ text: String, dictionary: [DictionaryEntry], level: CleanupLevel) async throws -> String {
        guard let model else { throw CoreError.message("Tidy model is not prepared.") }
        let vocab = llama_model_get_vocab(model)!
        let template = cleanupModel == .custom ? llama_model_chat_template(model, nil).map { String(cString: $0) } : nil
        func prompt(for text: String) -> [TidyPrompt.Segment] {
            cleanupModel == .custom
                ? TidyPrompt.customSegments(text: text, dictionary: dictionary, template: template)
                : TidyPrompt.segments(model: cleanupModel, text: text, dictionary: dictionary, level: level)
        }
        // The scaffolding is the same for every chunk, so measure it once and size the chunks from what is left.
        let overhead = tokenize(prompt(for: ""), vocab: vocab).count
        let room = max(TidyPrompt.Limits.minPromptTokens, TidyPrompt.Limits.maxPromptTokens - overhead)
        var pending = TidyPrompt.chunks(of: text, maxCharacters: room * TidyPrompt.Limits.charactersPerToken)
        var cleaned: [String] = [], chunks: [TidyPrompt.Chunk] = []
        while !pending.isEmpty {
            try Task.checkCancellation()
            let chunk = pending.removeFirst()
            let tokens = tokenize(prompt(for: chunk.text), vocab: vocab)
            guard tokens.count <= TidyPrompt.Limits.maxPromptTokens else {
                // The character estimate was optimistic for this text, so split it again, smaller.
                let scaled = max(1, chunk.text.count * TidyPrompt.Limits.maxPromptTokens / tokens.count)
                var smaller = TidyPrompt.chunks(of: chunk.text, maxCharacters: scaled)
                guard smaller.count > 1 else { throw CoreError.message("Dictation is too long for the tidy model context.") }
                smaller[smaller.count - 1].endsParagraph = chunk.endsParagraph
                pending.insert(contentsOf: smaller, at: 0)
                continue
            }
            cleaned.append(try generate(tokens, model: model, vocab: vocab))
            chunks.append(chunk)
        }
        let output = TidyPrompt.joining(cleaned, chunks: chunks)
        guard !output.isEmpty else { throw CoreError.message("\(cleanupModel.shortName) returned empty output.") }
        return output
    }

    /// Tokenizes each segment with its own special-token setting, so dictated text can never become a control token.
    private func tokenize(_ segments: [TidyPrompt.Segment], vocab: OpaquePointer) -> [llama_token] {
        var tokens: [llama_token] = []
        for segment in segments where !segment.text.isEmpty {
            // BOS/EOS belong at the very start of the prompt only, as when the whole prompt was one string.
            let addSpecial = tokens.isEmpty
            var capacity = segment.text.utf8.count + 16
            var buffer = [llama_token](repeating: 0, count: capacity)
            var count = llama_tokenize(vocab, segment.text, Int32(segment.text.utf8.count), &buffer, Int32(capacity), addSpecial, segment.parseSpecial)
            if count < 0 {
                capacity = Int(-count) + 8
                buffer = [llama_token](repeating: 0, count: capacity)
                count = llama_tokenize(vocab, segment.text, Int32(segment.text.utf8.count), &buffer, Int32(capacity), addSpecial, segment.parseSpecial)
            }
            guard count > 0 else { continue }
            tokens.append(contentsOf: buffer.prefix(Int(count)))
        }
        return tokens
    }

    /// The context for this model, created on first use and reused by every later dictation.
    private func ensureContext(_ model: OpaquePointer) throws -> OpaquePointer {
        if let context { return context }
        var params = llama_context_default_params()
        params.n_ctx = UInt32(TidyPrompt.Limits.nContext)
        params.n_batch = UInt32(TidyPrompt.Limits.batchSize)
        guard let created = llama_init_from_model(model, params) else { throw CoreError.message("Could not initialize the \(cleanupModel.shortName) context.") }
        context = created
        return created
    }

    /// Drops a context a failed decode may have left unusable; the next run builds a fresh one.
    private func discardContext() {
        if let context { llama_free(context); self.context = nil }
    }

    /// Runs one clean-up over a tokenized prompt, reusing the actor's context.
    private func generate(_ prompt: [llama_token], model: OpaquePointer, vocab: OpaquePointer) throws -> String {
        let context = try ensureContext(model)
        // A previous run may have thrown or been cancelled mid-generation, so every run starts from clean memory.
        llama_memory_clear(llama_get_memory(context), true)
        for offset in stride(from: 0, to: prompt.count, by: TidyPrompt.Limits.batchSize) {
            var batch = Array(prompt[offset..<min(offset + TidyPrompt.Limits.batchSize, prompt.count)])
            let status = batch.withUnsafeMutableBufferPointer { llama_decode(context, llama_batch_get_one($0.baseAddress, Int32($0.count))) }
            guard status == 0 else {
                discardContext()
                throw CoreError.message("\(cleanupModel.shortName) prompt decoding failed (\(status)).")
            }
        }
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        var bytes = [UInt8](), ended = false
        for _ in 0..<TidyPrompt.Limits.outputBudget(promptTokens: prompt.count) {
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
            // A small model that starts looping a phrase will not stop on its own, so the loop ends the answer.
            if cleanupModel == .lfm3, TidyPrompt.isRepeating(String(decoding: bytes, as: UTF8.self)) { ended = true; break }
            guard llama_decode(context, llama_batch_get_one(&token, 1)) == 0 else {
                discardContext()
                throw CoreError.message("\(cleanupModel.shortName) generation failed.")
            }
        }
        var output = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanupModel == .custom { output = TidyPrompt.strippingThinking(output) }
        if cleanupModel == .lfm3 { output = TidyPrompt.trimmingCommentary(output) }
        // A run that hit the token limit still holds a usable cleanup when it stopped on a finished sentence.
        if !ended, !(cleanupModel == .lfm3 && TidyPrompt.isCompleteCleanup(output)) {
            throw CoreError.message("\(cleanupModel.shortName) output exceeded its token limit.")
        }
        guard !output.isEmpty else { throw CoreError.message("\(cleanupModel.shortName) returned empty output.") }
        return output
    }
}
