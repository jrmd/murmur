import Foundation
import AVFoundation
import FluidAudio

public struct DictationResult: Sendable {
    public let raw: String
    public let final: String
    /// Why clean-up was skipped when the raw transcript had to be used instead (nil when clean-up ran or was switched off).
    public let cleanupFailure: String?
    public init(raw: String, final: String, cleanupFailure: String? = nil) { self.raw = raw; self.final = final; self.cleanupFailure = cleanupFailure }
}
public enum DictationState: Sendable, Equatable { case idle, preparing, listening, transcribing, tidying, error(String) }
public struct PrepareProgress: Sendable, CustomStringConvertible {
    public let phase: String
    public let fractionCompleted: Double?
    public init(phase: String, fractionCompleted: Double? = nil) { self.phase = phase; self.fractionCompleted = fractionCompleted }
    public var description: String { fractionCompleted.map { "\(phase) — \(Int($0 * 100))%" } ?? phase }
}

private final class Broadcast<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
    private var latest: Value?
    init(_ initial: Value? = nil) { latest = initial }
    func stream() -> AsyncStream<Value> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c in
            let id = UUID(); lock.lock(); continuations[id] = c; if let latest { c.yield(latest) }; lock.unlock()
            c.onTermination = { [weak self] _ in self?.remove(id) }
        }
    }
    private func remove(_ id: UUID) { lock.lock(); continuations.removeValue(forKey: id); lock.unlock() }
    func send(_ value: Value) { lock.lock(); latest = value; let targets = Array(continuations.values); lock.unlock(); targets.forEach { $0.yield(value) } }
}

private final class Capture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples = [Float]()
    private var failure: Error?
    private let levels: Broadcast<Float>
    init(levels: Broadcast<Float>) { self.levels = levels }
    func start() throws {
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else { throw CoreError.message("The microphone format is unavailable.") }
        input.installTap(onBus: 0, bufferSize: 4096, format: source) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / source.sampleRate)) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false, error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, inputStatus in
                if supplied { inputStatus.pointee = .noDataNow; return nil }
                supplied = true; inputStatus.pointee = .haveData; return buffer
            }
            if status == .error { self.lock.lock(); self.failure = error ?? CoreError.message("Audio conversion failed."); self.lock.unlock(); return }
            guard let channel = converted.floatChannelData?[0] else { return }
            let data = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
            let rms = data.isEmpty ? 0 : sqrt(data.reduce(Float(0)) { $0 + $1 * $1 } / Float(data.count))
            self.lock.lock(); self.samples.append(contentsOf: data); self.lock.unlock()
            self.levels.send(min(1, rms * 5))
        }
        do { engine.prepare(); try engine.start() } catch { input.removeTap(onBus: 0); throw error }
    }
    func stop() throws -> [Float] {
        engine.stop(); engine.inputNode.removeTap(onBus: 0); levels.send(0)
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }; return samples
    }
}

public actor DictationPipeline {
    private let progressEvents = Broadcast<PrepareProgress>()
    private let levelEvents = Broadcast<Float>(0)
    private let stateEvents = Broadcast<DictationState>(.idle)
    private var currentState: DictationState = .idle
    private var manager: AsrManager?
    private var capture: Capture?
    private var tidier: any TextTidying
    /// False when a tidier was injected (tests), in which case `setCleanupModel` leaves it alone.
    private let swappableTidier: Bool
    private var cleanupModel = CleanupModel.murmurClean
    private let dictionary: DictionaryStore?
    private var cleanupEnabled = true
    private var cleanupLevel = CleanupLevel.balanced
    private var speechModel = SpeechModel.parakeetV3
    public init(cleanupModel: CleanupModel = .murmurClean) { self.cleanupModel = cleanupModel; tidier = LlamaTidier(model: cleanupModel); swappableTidier = true; dictionary = nil }
    public init(tidier: any TextTidying) { self.tidier = tidier; swappableTidier = false; dictionary = nil }
    public init(dictionary: DictionaryStore, cleanupModel: CleanupModel = .murmurClean) {
        self.dictionary = dictionary; self.cleanupModel = cleanupModel; tidier = LlamaTidier(model: cleanupModel); swappableTidier = true
    }
    public init(dictionary: DictionaryStore, tidier: any TextTidying) { self.dictionary = dictionary; self.tidier = tidier; swappableTidier = false }
    /// Switch the clean-up pass on or off; when off the dictionary-corrected transcript is returned as is.
    public func setCleanupEnabled(_ enabled: Bool) { cleanupEnabled = enabled }
    public func setCleanupLevel(_ level: CleanupLevel) { cleanupLevel = level }
    /// Choosing a different speech model unloads the current one; call `prepare()` to load it.
    public func setSpeechModel(_ model: SpeechModel) { if model != speechModel { speechModel = model; manager = nil } }
    /// Choosing a different clean-up model unloads the current one; call `prepare()` to download and load the new one.
    /// `reload` rebuilds the tidier even for the same model, for a custom model whose file changed.
    public func setCleanupModel(_ model: CleanupModel, reload: Bool = false) async {
        guard swappableTidier, reload || model != cleanupModel else { return }
        await tidier.unload()
        cleanupModel = model; tidier = LlamaTidier(model: model)
    }
    public func unloadSpeech() { manager = nil }
    public func unloadCleanup() async { await tidier.unload() }
    public var progress: AsyncStream<PrepareProgress> { progressEvents.stream() }
    public var audioLevel: AsyncStream<Float> { levelEvents.stream() }
    public var state: AsyncStream<DictationState> { stateEvents.stream() }
    private func setState(_ value: DictationState) { currentState = value; stateEvents.send(value) }
    public func prepare() async throws {
        guard currentState == .idle || isError else { throw CoreError.message("Dictation is busy.") }
        setState(.preparing)
        do {
            progressEvents.send(.init(phase: "Preparing Parakeet"))
            let events = progressEvents
            let models = try await AsrModels.downloadAndLoad(version: speechModel.asrVersion, progressHandler: { p in events.send(.init(phase: "Preparing Parakeet", fractionCompleted: p.fractionCompleted)) })
            let manager = AsrManager(config: .default); try await manager.loadModels(models)
            progressEvents.send(.init(phase: "Downloading and loading \(cleanupModel.shortName)"))
            try await tidier.prepare()
            self.manager = manager
            progressEvents.send(.init(phase: "Ready", fractionCompleted: 1)); setState(.idle)
        } catch { setState(.error(error.localizedDescription)); throw error }
    }
    private var isError: Bool { if case .error = currentState { return true }; return false }
    public func start() async throws {
        guard (currentState == .idle || isError), manager != nil else { throw CoreError.message("Prepare models before recording, and wait for any current dictation to finish.") }
        setState(.listening)
        do {
            let granted: Bool
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { granted = true }
            else { granted = await AVCaptureDevice.requestAccess(for: .audio) }
            guard granted else { throw CoreError.message("Microphone access was denied.") }
            let capture = Capture(levels: levelEvents); try capture.start(); self.capture = capture
        } catch { setState(.error(error.localizedDescription)); throw error }
    }
    public func stop() async throws -> DictationResult {
        guard currentState == .listening, let capture, let manager else { throw CoreError.message("No recording is in progress.") }
        setState(.transcribing); self.capture = nil
        do {
            let samples = try capture.stop()
            guard !samples.isEmpty else { throw CoreError.message("No microphone audio was captured.") }
            var decoderState = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
            let raw = try await manager.transcribe(samples, decoderState: &decoderState).text
            let selectedStore = dictionary
            let entries = try await MainActor.run {
                let store = selectedStore ?? DictionaryStore()
                if let error = store.persistenceError { throw CoreError.message("Could not read dictionary: \(error)") }
                return store.entries
            }
            let corrected = DictionaryReplacer.apply(raw, entries: entries)
            if cleanupEnabled { setState(.tidying) }
            var final = corrected, failure: String?
            if cleanupEnabled, !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // A failed clean-up must never lose the dictation: fall back to the transcript.
                do { final = try await tidier.tidy(corrected, dictionary: entries, level: cleanupLevel) }
                catch is CancellationError { throw CancellationError() }
                catch { final = corrected; failure = error.localizedDescription }
            }
            setState(.idle); return DictationResult(raw: raw, final: final, cleanupFailure: failure)
        } catch { setState(.error(error.localizedDescription)); throw error }
    }
}
