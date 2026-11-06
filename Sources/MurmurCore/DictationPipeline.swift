import Foundation
import AVFoundation
import FluidAudio

public struct DictationResult: Sendable {
    public let raw: String
    public let final: String
    /// Why clean-up was skipped when the raw transcript had to be used instead (nil when clean-up ran or was switched off).
    public let cleanupFailure: String?
    /// How long the tidy step took, when it ran.
    public let cleanupDuration: TimeInterval?
    public init(raw: String, final: String, cleanupFailure: String? = nil, cleanupDuration: TimeInterval? = nil) {
        self.raw = raw; self.final = final; self.cleanupFailure = cleanupFailure; self.cleanupDuration = cleanupDuration
    }
}
public enum DictationState: Sendable, Equatable { case idle, preparing, listening, transcribing, tidying, error(String) }
/// Something the app has to react to while a recording is running.
public enum PipelineEvent: Sendable, Equatable { case maxDurationReached }
public struct PrepareProgress: Sendable, CustomStringConvertible {
    public let phase: String
    public let fractionCompleted: Double?
    public init(phase: String, fractionCompleted: Double? = nil) { self.phase = phase; self.fractionCompleted = fractionCompleted }
    public var description: String { fractionCompleted.map { "\(phase) — \(Int($0 * 100))%" } ?? phase }
}

/// The decisions the pipeline makes about a recording, kept pure so they can be tested without a microphone or a model.
enum PipelineRules {
    static let sampleRate = 16_000
    /// FluidAudio rejects anything shorter than 0.3 s (`ASRConstants.minimumRequiredSamples`), so a stray tap is dropped instead.
    static let minimumSamples = 4_800
    /// Five minutes of audio; anything longer is dropped rather than buffered.
    static let maximumSamples = 5 * 60 * sampleRate
    /// Whether a start that was waiting for the microphone is still the recording the app wants.
    static func isCurrent(start: Int, current: Int) -> Bool { start == current }
    /// Whether the captured audio is long enough for the speech model.
    static func isTranscribable(_ sampleCount: Int) -> Bool { sampleCount >= minimumSamples }
    /// Whether the capture may keep appending samples.
    static func accepts(_ sampleCount: Int) -> Bool { sampleCount < maximumSamples }
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
    private var observer: NSObjectProtocol?
    private var stopped = false
    private var limitSent = false
    private let levels: Broadcast<Float>
    private let onLimit: @Sendable () -> Void
    init(levels: Broadcast<Float>, onLimit: @escaping @Sendable () -> Void) { self.levels = levels; self.onLimit = onLimit }
    func start() throws {
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else { throw CoreError.message("The microphone format is unavailable.") }
        // AirPods connecting mid-recording stop the engine; remember it so stop() can say why the audio ended.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self, !self.engine.isRunning else { return }
            self.lock.lock(); if self.failure == nil { self.failure = CoreError.message("The microphone changed during recording.") }; self.lock.unlock()
        }
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
            self.lock.lock()
            let room = PipelineRules.maximumSamples - self.samples.count
            if room > 0 { self.samples.append(contentsOf: data.prefix(room)) }
            let reachedLimit = self.samples.count >= PipelineRules.maximumSamples && !self.limitSent
            if reachedLimit { self.limitSent = true }
            self.lock.unlock()
            if reachedLimit { self.onLimit() }
            self.levels.send(min(1, rms * 5))
        }
        do { engine.prepare(); try engine.start() } catch { input.removeTap(onBus: 0); removeObserver(); throw error }
    }
    func stop() throws -> [Float] {
        lock.lock(); let alreadyStopped = stopped; stopped = true; lock.unlock()
        removeObserver()
        if !alreadyStopped { engine.stop(); engine.inputNode.removeTap(onBus: 0); levels.send(0) }
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }; return samples
    }
    private func removeObserver() {
        lock.lock(); let observer = self.observer; self.observer = nil; lock.unlock()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

public actor DictationPipeline {
    private let progressEvents = Broadcast<PrepareProgress>()
    private let levelEvents = Broadcast<Float>(0)
    private let stateEvents = Broadcast<DictationState>(.idle)
    private let pipelineEvents = Broadcast<PipelineEvent>()
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
    /// Bumped whenever the loaded models change, so a prepare() that finishes late can tell it is stale.
    private var modelGeneration = 0
    /// Bumped by every start(), stop() and cancel(), so a start() still waiting for the microphone can tell it was overtaken.
    private var startToken = 0
    private static let emptyResult = DictationResult(raw: "", final: "")
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
    public func setSpeechModel(_ model: SpeechModel) { if model != speechModel { speechModel = model; manager = nil; modelGeneration &+= 1 } }
    /// Choosing a different clean-up model unloads the current one; call `prepare()` to download and load the new one.
    /// `reload` rebuilds the tidier even for the same model, for a custom model whose file changed.
    public func setCleanupModel(_ model: CleanupModel, reload: Bool = false) async {
        guard swappableTidier, reload || model != cleanupModel else { return }
        modelGeneration &+= 1
        await tidier.unload()
        cleanupModel = model; tidier = LlamaTidier(model: model)
    }
    public func unloadSpeech() { manager = nil; modelGeneration &+= 1 }
    public func unloadCleanup() async { modelGeneration &+= 1; await tidier.unload() }
    public var progress: AsyncStream<PrepareProgress> { progressEvents.stream() }
    public var audioLevel: AsyncStream<Float> { levelEvents.stream() }
    public var state: AsyncStream<DictationState> { stateEvents.stream() }
    /// Recording events the app has to act on, such as the recording hitting its maximum length.
    public var events: AsyncStream<PipelineEvent> { pipelineEvents.stream() }
    private func setState(_ value: DictationState) { currentState = value; stateEvents.send(value) }
    public func prepare() async throws {
        guard currentState == .idle || isError else { throw CoreError.message("Dictation is busy.") }
        let generation = modelGeneration
        setState(.preparing)
        do {
            let speechName = speechModel.shortName
            progressEvents.send(.init(phase: "Preparing \(speechName)"))
            let events = progressEvents
            let models = try await AsrModels.downloadAndLoad(version: speechModel.asrVersion, progressHandler: { p in events.send(.init(phase: "Preparing \(speechName)", fractionCompleted: p.fractionCompleted)) })
            try ensureCurrent(generation)
            let manager = AsrManager(config: .default); try await manager.loadModels(models)
            try ensureCurrent(generation)
            let cleanupName = cleanupModel.shortName
            progressEvents.send(.init(phase: "Loading \(cleanupName)"))
            try await tidier.prepare(progress: { events.send(.init(phase: "Downloading \(cleanupName)", fractionCompleted: $0)) })
            try ensureCurrent(generation)
            self.manager = manager
            progressEvents.send(.init(phase: "Ready", fractionCompleted: 1)); setState(.idle)
        } catch {
            // A model swapped out from under us is not a failure the user should see as an error.
            guard generation == modelGeneration else { setState(.idle); throw CoreError.message("The model changed while it was loading.") }
            setState(.error(error.localizedDescription)); throw error
        }
    }
    private func ensureCurrent(_ generation: Int) throws {
        guard generation == modelGeneration else { throw CoreError.message("The model changed while it was loading.") }
    }
    private var isError: Bool { if case .error = currentState { return true }; return false }
    public func start() async throws {
        guard (currentState == .idle || isError), manager != nil else { throw CoreError.message("Prepare models before recording, and wait for any current dictation to finish.") }
        startToken &+= 1
        let token = startToken
        setState(.listening)
        do {
            let granted: Bool
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { granted = true }
            else { granted = await AVCaptureDevice.requestAccess(for: .audio) }
            // stop() or cancel() may have run while the permission prompt was up; then this recording is already over.
            guard PipelineRules.isCurrent(start: token, current: startToken) else { return }
            guard granted else { throw CoreError.message("Microphone access was denied.") }
            let events = pipelineEvents
            let capture = Capture(levels: levelEvents, onLimit: { events.send(.maxDurationReached) })
            try capture.start(); self.capture = capture
        } catch { setState(.error(error.localizedDescription)); throw error }
    }
    public func stop() async throws -> DictationResult {
        // A stop with nothing recording at all is a no-op, not an error.
        guard currentState == .listening else { return Self.emptyResult }
        // A stop can also arrive while start() is still waiting for the microphone; then there is nothing to transcribe.
        guard let capture else { startToken &+= 1; setState(.idle); return Self.emptyResult }
        setState(.transcribing); self.capture = nil
        do {
            let samples = try capture.stop()
            // An accidental tap of the hotkey is not an error, it is just nothing to transcribe.
            guard PipelineRules.isTranscribable(samples.count) else { setState(.idle); return Self.emptyResult }
            guard let manager else { throw CoreError.message("The speech model was unloaded during recording.") }
            var decoderState = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
            let raw = try await manager.transcribe(samples, decoderState: &decoderState).text
            let selectedStore = dictionary
            // A dictionary file that failed to load must not cost the user their dictation: carry on with what did load.
            let entries = await MainActor.run { (selectedStore ?? DictionaryStore()).entries }
            let corrected = DictionaryReplacer.apply(raw, entries: entries)
            if cleanupEnabled { setState(.tidying) }
            var final = corrected, failure: String?, duration: TimeInterval?
            if cleanupEnabled, !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let tidied = try await Self.tidy(corrected, using: tidier, dictionary: entries, level: cleanupLevel)
                final = tidied.text; failure = tidied.failure; duration = tidied.duration
            }
            setState(.idle); return DictationResult(raw: raw, final: final, cleanupFailure: failure, cleanupDuration: duration)
        } catch { setState(.error(error.localizedDescription)); throw error }
    }
    /// Abandons the current recording without transcribing it.
    public func cancel() async {
        // Past this point the audio is already being transcribed; only a recording can be abandoned.
        guard currentState == .listening else { return }
        startToken &+= 1
        if let capture { self.capture = nil; _ = try? capture.stop() }
        setState(.idle)
    }
    /// A failed clean-up must never lose the dictation: fall back to the transcript and say why.
    static func tidy(_ text: String, using tidier: any TextTidying, dictionary: [DictionaryEntry], level: CleanupLevel) async throws -> (text: String, failure: String?, duration: TimeInterval) {
        let started = Date()
        do { return (try await tidier.tidy(text, dictionary: dictionary, level: level), nil, Date().timeIntervalSince(started)) }
        catch is CancellationError { throw CancellationError() }
        catch { return (text, error.localizedDescription, Date().timeIntervalSince(started)) }
    }
}
