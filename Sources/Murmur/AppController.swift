import AppKit
import AVFoundation
import ApplicationServices
import Combine
import IOKit.hid
import MurmurCore
import ServiceManagement

/// How the shortcut starts and stops a dictation.
enum DictationMode: String, CaseIterable {
    case hold = "Hold"
    case toggle = "Toggle"
}

/// What happens to the text once it has been transcribed.
enum OutputMode: String {
    case paste, copy
}

/// The dictation lifecycle the UI switches on; the pipeline's own state carries the error payload.
enum DictationStatus: Equatable {
    case idle, preparing, listening, transcribing, tidying, error
}

@MainActor
final class AppController: ObservableObject {
    /// Fn / Globe: the default because it rarely clashes with other apps.
    static let defaultHotkeyCode = 63
    static let defaultHotkeyModifiers = Int(NSEvent.ModifierFlags.function.rawValue)

    @Published private(set) var status: DictationStatus = .idle { didSet { OverlayPresenter.shared.update(controller: self) } }
    @Published private(set) var menuSymbol = "waveform"
    @Published var errorMessage: String?
    /// The typed error behind `errorMessage`; the overlay picks its screen from `kind`, never from the text.
    @Published private(set) var lastError: DictationError?
    @Published private(set) var isPreparing = false
    @Published private(set) var prepareDescription = ""
    @Published private(set) var prepareFraction: Double?
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var microphoneLevel: Float = 0
    @Published private(set) var inputDeviceName = "Default microphone"
    @Published private(set) var lastResult: DictationResult?
    @Published private(set) var cleanupDuration: TimeInterval?
    @Published private(set) var lastInserted: String?
    @Published private(set) var cleanupNotice: String?
    /// A short, non-error message for the menu, such as the recording hitting its length limit.
    @Published private(set) var notice: String?
    @Published private(set) var listeningStartedAt: Date?
    @Published var outputMode = OutputMode(rawValue: UserDefaults.standard.string(forKey: "outputMode") ?? "") ?? .paste {
        didSet { UserDefaults.standard.set(outputMode.rawValue, forKey: "outputMode") }
    }
    @Published var playSounds = UserDefaults.standard.object(forKey: "playSounds") as? Bool ?? true { didSet { UserDefaults.standard.set(playSounds, forKey: "playSounds") } }
    @Published var cleanupLevel = CleanupLevel(rawValue: UserDefaults.standard.string(forKey: "cleanupLevel") ?? "") ?? .balanced {
        didSet {
            UserDefaults.standard.set(cleanupLevel.rawValue, forKey: "cleanupLevel")
            Task { [pipeline, cleanupLevel] in await pipeline.setCleanupLevel(cleanupLevel) }
        }
    }
    @Published private(set) var cleanupModel = AppController.storedCleanupModel()
    /// The Hugging Face model and prompt behind `CleanupModel.custom`, once the user has set one up.
    @Published private(set) var customCleanup = CustomCleanupModel.stored
    @Published private(set) var speechModel = SpeechModel(rawValue: UserDefaults.standard.string(forKey: "speechModel") ?? "") ?? .parakeetV3
    /// Bumped whenever model files change on disk so views re-read install state and sizes.
    @Published private(set) var storageRevision = 0
    @Published var cleanupEnabled = UserDefaults.standard.object(forKey: "cleanupEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(cleanupEnabled, forKey: "cleanupEnabled")
            Task { [pipeline, cleanupEnabled] in await pipeline.setCleanupEnabled(cleanupEnabled) }
        }
    }
    @Published var isPracticing = false
    @Published var showOnboarding = false {
        didSet {
            if showOnboarding { OnboardingWindowPresenter.shared.show(controller: self) }
            else { OnboardingWindowPresenter.shared.close() }
        }
    }
    @Published var showSettings = false
    @Published private(set) var microphoneGranted = false
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var modelsReady = UserDefaults.standard.bool(forKey: "modelsReady")
    /// True once the pipeline has loaded the models in this process (modelsReady only says they are on disk).
    private var pipelineLoaded = false
    @Published var hotkeyCode = UserDefaults.standard.object(forKey: "hotkeyCode") as? Int ?? AppController.defaultHotkeyCode
    @Published var hotkeyModifiers = UserDefaults.standard.object(forKey: "hotkeyModifiers") as? Int ?? AppController.defaultHotkeyModifiers
    @Published var mode = DictationMode(rawValue: UserDefaults.standard.string(forKey: "dictationMode") ?? "") ?? .hold {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "dictationMode") }
    }
    /// The shortcut that re-pastes the last dictation; ⌥⇧V until the user records another.
    @Published var pasteLastKeyCode = UserDefaults.standard.object(forKey: "pasteLastKeyCode") as? Int ?? 9 {
        didSet { UserDefaults.standard.set(pasteLastKeyCode, forKey: "pasteLastKeyCode") }
    }
    @Published var pasteLastModifiers = UserDefaults.standard.object(forKey: "pasteLastModifiers") as? Int ?? Int(NSEvent.ModifierFlags.option.union(.shift).rawValue) {
        didSet { UserDefaults.standard.set(pasteLastModifiers, forKey: "pasteLastModifiers") }
    }

    let dictionary: DictionaryStore
    private let pipeline: DictationPipeline
    private var appearanceObservation: NSKeyValueObservation?
    private var hotkeyMonitor: HotkeyMonitor?
    private var heldHotkey = false
    private var stateTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    /// The one chain every recording step runs on, so a release can never overtake a press.
    private var flowTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Error>?
    /// Bumped by every prepare and by `cancelPreparing()`, so a prepare that finishes late leaves the UI alone.
    private var prepareGeneration = 0
    /// Set while a cancelled download's error is still on its way through the pipeline's state stream.
    private var ignoreNextPipelineError = false
    private var inputGrantedAtLaunch = false
    private var permissionPollTask: Task<Void, Never>?
    private var permissionPollingActive = false
    private var meterEngine: AVAudioEngine?
    private var resumeSetupAfterInputGrant = false
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    /// New installs get Murmur Clean; anyone who already downloaded LFM3 and never chose keeps it.
    private static func storedCleanupModel() -> CleanupModel {
        if let stored = UserDefaults.standard.string(forKey: "cleanupModel"), let model = CleanupModel(rawValue: stored), model != .custom || CustomCleanupModel.stored != nil { return model }
        return CleanupModel.lfm3.isInstalled && !CleanupModel.murmurClean.isInstalled ? .lfm3 : .murmurClean
    }

    var permissionsReady: Bool { microphoneGranted && inputMonitoringGranted && accessibilityGranted }
    var menuTitle: String { "Murmur · \(statusText)" }

    /// Display string for the readers that still show text (the menu bar title, Settings, onboarding).
    var statusText: String {
        switch status {
        case .idle: "Idle"
        case .preparing: "Preparing"
        case .listening: "Listening"
        case .transcribing: "Transcribing"
        case .tidying: "Tidying"
        case .error: "Error"
        }
    }

    init() {
        let store = DictionaryStore()
        dictionary = store
        pipeline = DictationPipeline(dictionary: store, cleanupModel: AppController.storedCleanupModel())
        Task { [pipeline, enabled = UserDefaults.standard.object(forKey: "cleanupEnabled") as? Bool ?? true, level = cleanupLevel, model = speechModel] in
            await pipeline.setCleanupEnabled(enabled)
            await pipeline.setCleanupLevel(level)
            await pipeline.setSpeechModel(model)
        }
        refreshPermissions()
        inputGrantedAtLaunch = inputMonitoringGranted
        if UserDefaults.standard.bool(forKey: "murmurRelaunchAfterInputGrant") {
            resumeSetupAfterInputGrant = true
            UserDefaults.standard.removeObject(forKey: "murmurRelaunchAfterInputGrant")
            UserDefaults.standard.set(3, forKey: "onboardingStep")
        }
        hotkeyMonitor = HotkeyMonitor { [weak self] isDown, keyCode, modifiers in
            guard let self else { return }
            let actual = modifiers.intersection(.deviceIndependentFlagsMask)
            let pasteFlags = NSEvent.ModifierFlags(rawValue: UInt(self.pasteLastModifiers)).intersection(.deviceIndependentFlagsMask)
            if isDown, keyCode == self.pasteLastKeyCode, actual.isSuperset(of: pasteFlags) {
                Task { @MainActor in self.pasteLastDictation() }
                return
            }
            guard keyCode == self.hotkeyCode else { return }
            let wanted = NSEvent.ModifierFlags(rawValue: UInt(self.hotkeyModifiers))
            let matchesModifiers = keyCode == 63 ? true : actual.intersection([.command, .option, .control, .shift, .function]).rawValue == wanted.rawValue
            switch self.mode {
            case .toggle:
                if isDown && matchesModifiers { self.enqueueFlow { await self.toggleRecording() } }
            case .hold:
                if isDown && matchesModifiers && !self.heldHotkey {
                    self.heldHotkey = true
                    if UserDefaults.standard.integer(forKey: "onboardingStep") == 6 && self.showOnboarding { self.isPracticing = true; self.lastResult = nil }
                    self.enqueueFlow { await self.beginRecording() }
                } else if !isDown && self.heldHotkey {
                    self.heldHotkey = false
                    self.enqueueFlow { await self.finishRecording() }
                }
            }
        }
        hotkeyMonitor?.onEscape = { [weak self] in
            Task { @MainActor in self?.cancelDictation() }
        }
        subscribeToPipeline()
        BrandAssets.applyDockIcon()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in Task { @MainActor in BrandAssets.applyDockIcon() } }
        OverlayPresenter.shared.update(controller: self)
        startPermissionPolling()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            // An edit made in the last debounce window would otherwise be lost on quit.
            MainActor.assumeIsolated { self?.dictionary.flush() }
        }
        if modelsReady { Task { await prepare() } }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-obSettings") {
            Task { try? await Task.sleep(for: .seconds(2)); NSApp.activate(); NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        }
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-obIsland"), ProcessInfo.processInfo.arguments.indices.contains(i + 1) {
            let name = ProcessInfo.processInfo.arguments[i + 1]
            listeningStartedAt = Date().addingTimeInterval(-4)
            audioLevel = 0.6
            Task { try? await Task.sleep(for: .seconds(2)); OverlayPresenter.shared.debugShow(name, controller: self) }
        }
        #endif
        DispatchQueue.main.async { [weak self] in
            let debugOnboarding = ProcessInfo.processInfo.arguments.contains("-obStep")
            guard let self else { return }
            let modelsPending = !self.modelsReady && !self.modelsSkipped
            guard debugOnboarding || !self.permissionsReady || modelsPending || !UserDefaults.standard.bool(forKey: "onboardingFinished") || self.resumeSetupAfterInputGrant else { return }
            self.resumeSetupAfterInputGrant = false
            self.showOnboarding = true
        }
    }

    func refreshPermissions() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        inputMonitoringGranted = CGPreflightListenEventAccess() || access == kIOHIDAccessTypeGranted
        accessibilityGranted = AXIsProcessTrusted()
    }

    /// Keeps the fast permission poll running while a window that shows permission state is open.
    func setPermissionPolling(active: Bool) { permissionPollingActive = active }

    /// A missing permission is worth a one-second poll; once everything is granted, back off to five.
    private var needsFastPermissionPolling: Bool { !permissionsReady || showOnboarding || showSettings || permissionPollingActive }

    private func startPermissionPolling() {
        permissionPollTask?.cancel()
        permissionPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.needsFastPermissionPolling ? 1.0 : 5.0
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self.refreshPermissions()
            }
        }
    }

    var setupComplete: Bool { permissionsReady && modelsReady }
    var microphoneAuthorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    var inputMonitoringAuthorization: String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return "Granted"
        case kIOHIDAccessTypeDenied: return "Denied"
        default: return inputMonitoringGranted ? "Granted" : "Pending"
        }
    }
    var inputNeedsRelaunch: Bool { inputMonitoringGranted && !inputGrantedAtLaunch }

    func requestMicrophone() async {
        microphoneGranted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
        if microphoneGranted { startMicrophoneMeter() }
    }

    func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        _ = CGRequestListenEventAccess()
        refreshPermissions()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }

    func prepare() async {
        guard !isPreparing else { return }
        isPreparing = true
        errorMessage = nil
        lastError = nil
        prepareGeneration &+= 1
        let generation = prepareGeneration
        // Held so `cancelPreparing()` can stop a download that would otherwise run to completion.
        let task = Task { [pipeline] in try await pipeline.prepare() }
        prepareTask = task
        do {
            try await task.value
            guard generation == prepareGeneration else { return }
            pipelineLoaded = true
            modelsReady = true
            UserDefaults.standard.set(true, forKey: "modelsReady")
            UserDefaults.standard.removeObject(forKey: "modelsSkipped")
        } catch {
            // The pipeline reports the failure through its state stream; a cancelled download is not a failure.
            guard generation == prepareGeneration else { return }
            markModelsNotReady()
        }
        guard generation == prepareGeneration else { return }
        isPreparing = false
        prepareTask = nil
    }

    /// Abandons an in-flight download or model load. The downloader keeps its `.part` file, so the next attempt resumes.
    func cancelPreparing() {
        guard isPreparing else { return }
        prepareGeneration &+= 1
        prepareTask?.cancel()
        prepareTask = nil
        isPreparing = false
        prepareDescription = ""
        prepareFraction = nil
        errorMessage = nil
        lastError = nil
        // The pipeline reports the cancelled download as an error; the user asked for it, so keep it out of the UI.
        ignoreNextPipelineError = true
        if status == .preparing { status = .idle }
    }

    /// Runs one recording step after the previous one, so a key release can never overtake its press.
    private func enqueueFlow(_ operation: @escaping @MainActor () async -> Void) {
        let previous = flowTask
        flowTask = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    func beginRecording() async {
        guard permissionsReady else { showOnboarding = true; return }
        // After "Skip for now" the shortcut must not start a large download on its own.
        if !modelsReady && modelsSkipped { errorMessage = "Download the models in Settings › Models to start dictating."; status = .error; return }
        errorMessage = nil
        lastError = nil
        notice = nil
        if !pipelineLoaded {
            await prepare()
            // The shortcut may have been released while the models were loading.
            guard pipelineLoaded, mode == .toggle || heldHotkey else { return }
        }
        do {
            try await pipeline.start()
            // The key may have been released while the microphone was opening; never leave it recording.
            if mode == .hold && !heldHotkey { await finishRecording() }
        } catch {
            errorMessage = error.localizedDescription
            status = .error
        }
    }

    func finishRecording() async {
        do {
            let result = try await pipeline.stop()
            errorMessage = nil
            cleanupNotice = result.cleanupFailure
            // A tap or a no-op produces an empty result: nothing to paste, nothing to report, and the practice stays open.
            guard !result.final.isEmpty else { return }
            lastResult = result
            cleanupDuration = result.cleanupDuration
            if isPracticing { isPracticing = false } else { deliver(result.final, seconds: result.cleanupDuration) }
        } catch {
            errorMessage = error.localizedDescription
            status = .error
        }
    }

    /// Esc while listening: throw the recording away instead of transcribing it.
    func cancelDictation() {
        guard status == .listening else { return }
        enqueueFlow { await self.cancelListening() }
    }

    private func cancelListening() async {
        await pipeline.cancel()
        OverlayPresenter.shared.dismiss()
    }

    func pasteLastDictation() {
        guard let text = lastInserted, !text.isEmpty else { return }
        deliver(text, seconds: nil)
    }

    private func deliver(_ text: String, seconds: Double?) {
        lastInserted = text
        guard outputMode == .paste else {
            TextInserter.copyOnly(text)
            OverlayPresenter.shared.showPasted(text: text, appName: nil, seconds: seconds, verb: "Copied to clipboard")
            return
        }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        guard TextInserter.insert(text) else {
            // Nothing could be posted: leave the text on the clipboard so the user can paste it themselves.
            TextInserter.copyOnly(text)
            let failure = DictationError(.other, "Couldn't paste — text copied to clipboard")
            errorMessage = failure.message
            lastError = failure
            status = .error
            return
        }
        OverlayPresenter.shared.showPasted(text: text, appName: app, seconds: seconds, verb: "Pasted")
    }

    // MARK: Models and storage

    var modelsOnDisk: Bool { speechModel.isInstalled && cleanupModel.isInstalled }

    /// Switches the clean-up model without downloading it; used while onboarding, where the download is its own step.
    func chooseCleanupModel(_ model: CleanupModel) async {
        guard !isPreparing, model != cleanupModel else { return }
        UserDefaults.standard.set(model.rawValue, forKey: "cleanupModel")
        cleanupModel = model
        await pipeline.setCleanupModel(model)
        pipelineLoaded = false
        if !model.isInstalled { markModelsNotReady() }
        storageRevision += 1
    }

    /// Switches the clean-up model and loads it, downloading it first if needed.
    func selectCleanupModel(_ model: CleanupModel) async {
        guard !isPreparing else { return }
        await chooseCleanupModel(model)
        if !pipelineLoaded { await prepare() }
        storageRevision += 1
    }

    /// Switches the speech model without downloading it; used while onboarding, where the download is its own step.
    func chooseSpeechModel(_ model: SpeechModel) async {
        guard !isPreparing, model != speechModel else { return }
        UserDefaults.standard.set(model.rawValue, forKey: "speechModel")
        speechModel = model
        await pipeline.setSpeechModel(model)
        pipelineLoaded = false
        if !model.isInstalled { markModelsNotReady() }
        storageRevision += 1
    }

    func selectSpeechModel(_ model: SpeechModel) async {
        guard !isPreparing else { return }
        UserDefaults.standard.set(model.rawValue, forKey: "speechModel")
        speechModel = model
        await pipeline.setSpeechModel(model)
        pipelineLoaded = false
        await prepare()
        storageRevision += 1
    }

    /// Saves the custom clean-up model and prompt, switches to it, and downloads it if needed.
    /// A prompt-only edit takes effect on the next dictation; a different file replaces the old download.
    func saveCustomCleanup(_ model: CustomCleanupModel) async {
        guard !isPreparing, model.isValid else { return }
        let previous = CustomCleanupModel.stored
        let fileChanged = previous?.localURL != model.localURL
        if fileChanged && cleanupModel == .custom { await pipeline.unloadCleanup() }
        CustomCleanupModel.store(model)
        customCleanup = model
        if fileChanged, let previous { try? FileManager.default.removeItem(at: previous.localURL) }
        if fileChanged && cleanupModel == .custom {
            await pipeline.setCleanupModel(.custom, reload: true)
            pipelineLoaded = false
            if !CleanupModel.custom.isInstalled { markModelsNotReady() }
        }
        await selectCleanupModel(.custom)
    }

    func removeSpeechModel(_ model: SpeechModel) async {
        guard !isPreparing else { return }
        if model == speechModel {
            await pipeline.unloadSpeech()
            pipelineLoaded = false
            markModelsNotReady()
        }
        do { try ModelStorage.remove(model) } catch { errorMessage = error.localizedDescription }
        storageRevision += 1
    }

    func removeCleanupModel(_ model: CleanupModel) async {
        guard !isPreparing else { return }
        if model == cleanupModel {
            await pipeline.unloadCleanup()
            pipelineLoaded = false
            markModelsNotReady()
        }
        do { try ModelStorage.remove(model) } catch { errorMessage = error.localizedDescription }
        storageRevision += 1
    }

    private func markModelsNotReady() {
        modelsReady = false
        UserDefaults.standard.set(false, forKey: "modelsReady")
    }

    // MARK: Launch at login

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { errorMessage = "Launch at login: \(error.localizedDescription)" }
        objectWillChange.send()
    }

    private func tick(_ name: String) {
        guard playSounds, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.35
        sound.play()
    }

    func toggleRecording() async {
        switch status {
        case .listening: await finishRecording()
        case .idle, .error: await beginRecording()
        // A press mid-transition must not corrupt the flow; the next press lands once the pipeline is settled.
        case .preparing, .transcribing, .tidying: break
        }
    }

    func saveHotkey() {
        UserDefaults.standard.set(hotkeyCode, forKey: "hotkeyCode")
        UserDefaults.standard.set(hotkeyModifiers, forKey: "hotkeyModifiers")
        UserDefaults.standard.set(mode.rawValue, forKey: "dictationMode")
    }

    func finishOnboarding() { UserDefaults.standard.set(true, forKey: "onboardingFinished") }

    /// True when the user chose "Skip for now" on the models step and has not downloaded them since.
    var modelsSkipped: Bool { UserDefaults.standard.bool(forKey: "modelsSkipped") }
    func skipModels() { UserDefaults.standard.set(true, forKey: "modelsSkipped") }

    func relaunch() {
        UserDefaults.standard.set(true, forKey: "murmurRelaunchAfterInputGrant")
        UserDefaults.standard.set(3, forKey: "onboardingStep")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }

    func startPractice() {
        lastResult = nil
        cleanupDuration = nil
        isPracticing = true
        enqueueFlow { await self.beginRecording() }
    }

    func openMicrophoneMeter() { if microphoneGranted { startMicrophoneMeter() } }

    func stopMicrophoneMeter() {
        meterEngine?.inputNode.removeTap(onBus: 0)
        meterEngine?.stop()
        meterEngine = nil
        microphoneLevel = 0
    }

    private func startMicrophoneMeter() {
        stopMicrophoneMeter()
        inputDeviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "Default microphone"
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let samples = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var sum: Float = 0
            for i in 0..<count { sum += samples[i] * samples[i] }
            let rms = sqrt(sum / Float(count))
            DispatchQueue.main.async { self?.microphoneLevel = min(1, max(0, rms * 8)) }
        }
        do { try engine.start(); meterEngine = engine }
        catch { inputDeviceName = "Microphone unavailable" }
    }

    private func subscribeToPipeline() {
        stateTask = Task {
            let stream = await pipeline.state
            for await state in stream {
                switch state {
                case .idle:
                    ignoreNextPipelineError = false
                    status = .idle; menuSymbol = "waveform"
                case .preparing:
                    ignoreNextPipelineError = false
                    status = .preparing; menuSymbol = "arrow.down.circle"
                case .listening:
                    ignoreNextPipelineError = false
                    listeningStartedAt = Date(); status = .listening; menuSymbol = "waveform.circle.fill"; tick("Tink")
                case .transcribing:
                    ignoreNextPipelineError = false
                    status = .transcribing; menuSymbol = "ellipsis"; tick("Pop")
                case .tidying:
                    ignoreNextPipelineError = false
                    status = .tidying; menuSymbol = "sparkles"
                case .error(let error):
                    if ignoreNextPipelineError {
                        // The download the user cancelled reports itself as an error; it is not one.
                        ignoreNextPipelineError = false
                        status = .idle; menuSymbol = "waveform"
                    } else {
                        lastError = error
                        errorMessage = error.message
                        status = .error; menuSymbol = "exclamationmark.triangle"
                    }
                }
            }
        }
        levelTask = Task {
            let stream = await pipeline.audioLevel
            for await level in stream { audioLevel = level }
        }
        progressTask = Task {
            let stream = await pipeline.progress
            for await progress in stream { prepareDescription = progress.phase; prepareFraction = progress.fractionCompleted }
        }
        eventsTask = Task {
            let stream = await pipeline.events
            for await event in stream {
                switch event {
                case .maxDurationReached:
                    // The recording hit its length limit: finish it rather than lose what was said.
                    let limit = "Reached the 5-minute limit"
                    notice = limit
                    OverlayPresenter.shared.announce(limit)
                    enqueueFlow { await self.finishRecording() }
                }
            }
        }
    }
}
