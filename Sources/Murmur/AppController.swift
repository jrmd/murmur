import AppKit
import AVFoundation
import ApplicationServices
import Combine
import IOKit.hid
import MurmurCore
import ServiceManagement

@MainActor
final class AppController: ObservableObject {
    @Published private(set) var statusText = "Idle" { didSet { OverlayPresenter.shared.update(controller: self) } }
    @Published private(set) var menuSymbol = "waveform"
    @Published var errorMessage: String?
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
    @Published private(set) var listeningStartedAt: Date?
    /// "paste" inserts into the active app; "copy" only puts the text on the clipboard.
    @Published var outputMode = UserDefaults.standard.string(forKey: "outputMode") ?? "paste" { didSet { UserDefaults.standard.set(outputMode, forKey: "outputMode") } }
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
    @Published var hotkeyCode = UserDefaults.standard.object(forKey: "hotkeyCode") as? Int ?? 63 // Fn / Globe
    @Published var hotkeyModifiers = UserDefaults.standard.object(forKey: "hotkeyModifiers") as? Int ?? Int(NSEvent.ModifierFlags.function.rawValue)
    @Published var mode = UserDefaults.standard.string(forKey: "dictationMode") ?? "Hold"

    let dictionary: DictionaryStore
    private let pipeline: DictationPipeline
    private var appearanceObservation: NSKeyValueObservation?
    private var hotkeyMonitor: HotkeyMonitor?
    private var heldHotkey = false
    private var stateTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var inputGrantedAtLaunch = false
    private var permissionPollTask: Task<Void, Never>?
    private var meterEngine: AVAudioEngine?
    private var tidyingStartedAt: Date?
    private var resumeSetupAfterInputGrant = false

    /// New installs get Murmur Clean; anyone who already downloaded LFM3 and never chose keeps it.
    private static func storedCleanupModel() -> CleanupModel {
        if let stored = UserDefaults.standard.string(forKey: "cleanupModel"), let model = CleanupModel(rawValue: stored), model != .custom || CustomCleanupModel.stored != nil { return model }
        return CleanupModel.lfm3.isInstalled && !CleanupModel.murmurClean.isInstalled ? .lfm3 : .murmurClean
    }

    var permissionsReady: Bool { microphoneGranted && inputMonitoringGranted && accessibilityGranted }
    var menuTitle: String { "Murmur · \(statusText)" }

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
            if isDown, keyCode == 9, modifiers.intersection(.deviceIndependentFlagsMask).isSuperset(of: [.option, .shift]) {
                Task { @MainActor in self?.pasteLastDictation() }
                return
            }
            guard let self, keyCode == self.hotkeyCode else { return }
            let actual = modifiers.intersection(.deviceIndependentFlagsMask)
            let wanted = NSEvent.ModifierFlags(rawValue: UInt(self.hotkeyModifiers))
            let matchesModifiers = keyCode == 63 ? true : actual.intersection([.command, .option, .control, .shift, .function]).rawValue == wanted.rawValue
            if self.mode == "Toggle" {
                if isDown && matchesModifiers { Task { await self.toggleRecording() } }
            } else {
                if isDown && matchesModifiers && !self.heldHotkey {
                    self.heldHotkey = true
                    if UserDefaults.standard.integer(forKey: "onboardingStep") == 6 && self.showOnboarding { self.isPracticing = true; self.lastResult = nil }
                    Task { await self.beginRecording() }
                } else if !isDown && self.heldHotkey {
                    self.heldHotkey = false
                    Task { await self.finishRecording() }
                }
            }
        }
        subscribeToPipeline()
        BrandAssets.applyDockIcon()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in Task { @MainActor in BrandAssets.applyDockIcon() } }
        OverlayPresenter.shared.update(controller: self)
        permissionPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.refreshPermissions()
            }
        }
        if modelsReady { Task { await prepare() } }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-obSettings") {
            Task { try? await Task.sleep(for: .seconds(2)); NSApp.activate(ignoringOtherApps: true); NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
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
        do { try await pipeline.prepare(); pipelineLoaded = true; modelsReady = true; UserDefaults.standard.set(true, forKey: "modelsReady"); UserDefaults.standard.removeObject(forKey: "modelsSkipped") }
        catch { errorMessage = error.localizedDescription; modelsReady = false; UserDefaults.standard.set(false, forKey: "modelsReady") }
        isPreparing = false
    }

    func beginRecording() async {
        guard permissionsReady else { showOnboarding = true; return }
        // After "Skip for now" the shortcut must not start a large download on its own.
        if !modelsReady && modelsSkipped { errorMessage = "Download the models in Settings › Models to start dictating."; return }
        errorMessage = nil
        if !pipelineLoaded {
            await prepare()
            // The shortcut may have been released while the models were loading.
            guard pipelineLoaded, mode == "Toggle" || heldHotkey else { return }
        }
        do { try await pipeline.start() }
        catch { errorMessage = error.localizedDescription; statusText = "Error" }
    }

    func finishRecording() async {
        do {
            let result = try await pipeline.stop()
            lastResult = result
            let final = result.final
            errorMessage = nil
            cleanupNotice = result.cleanupFailure
            if isPracticing { isPracticing = false }
            else if !final.isEmpty {
                deliver(final, seconds: cleanupDuration)
            }
        } catch { errorMessage = error.localizedDescription; statusText = "Error" }
    }

    func pasteLastDictation() {
        guard let text = lastInserted, !text.isEmpty else { return }
        deliver(text, seconds: nil)
    }

    private func deliver(_ text: String, seconds: Double?) {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        let copyOnly = outputMode == "copy"
        if copyOnly { TextInserter.copyOnly(text) } else { TextInserter.insert(text) }
        lastInserted = text
        OverlayPresenter.shared.showPasted(text: text, appName: copyOnly ? nil : app, seconds: seconds, verb: copyOnly ? "Copied to clipboard" : "Pasted")
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
        if statusText == "Listening" { await finishRecording() } else { await beginRecording() }
    }

    func saveHotkey() {
        UserDefaults.standard.set(hotkeyCode, forKey: "hotkeyCode")
        UserDefaults.standard.set(hotkeyModifiers, forKey: "hotkeyModifiers")
        UserDefaults.standard.set(mode, forKey: "dictationMode")
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
        Task { await beginRecording() }
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
                    statusText = "Idle"; menuSymbol = "waveform"
                    if let start = tidyingStartedAt { cleanupDuration = Date().timeIntervalSince(start); tidyingStartedAt = nil }
                case .preparing: statusText = "Preparing"; menuSymbol = "arrow.down.circle"
                case .listening: listeningStartedAt = Date(); statusText = "Listening"; menuSymbol = "waveform.circle.fill"; tick("Tink")
                case .transcribing: statusText = "Transcribing"; menuSymbol = "ellipsis"; tick("Pop")
                case .tidying: statusText = "Tidying"; menuSymbol = "sparkles"; tidyingStartedAt = Date()
                case .error(let message): statusText = "Error"; menuSymbol = "exclamationmark.triangle"; errorMessage = message
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
    }
}

private final class HotkeyMonitor {
    private var downToken: Any?
    private var upToken: Any?
    private var localDownToken: Any?
    private var localUpToken: Any?
    private var flagsToken: Any?
    private var localFlagsToken: Any?
    init(handler: @escaping (Bool, Int, NSEvent.ModifierFlags) -> Void) {
        downToken = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard !event.isARepeat else { return }
            handler(true, Int(event.keyCode), event.modifierFlags)
        }
        upToken = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { event in
            handler(false, Int(event.keyCode), event.modifierFlags)
        }
        localDownToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if !event.isARepeat { handler(true, Int(event.keyCode), event.modifierFlags) }
            return event
        }
        localUpToken = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            handler(false, Int(event.keyCode), event.modifierFlags)
            return event
        }
        flagsToken = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event.modifierFlags.contains(.function), Int(event.keyCode), event.modifierFlags)
        }
        localFlagsToken = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event.modifierFlags.contains(.function), Int(event.keyCode), event.modifierFlags)
            return event
        }
    }
    deinit {
        if let downToken { NSEvent.removeMonitor(downToken) }
        if let upToken { NSEvent.removeMonitor(upToken) }
        if let localDownToken { NSEvent.removeMonitor(localDownToken) }
        if let localUpToken { NSEvent.removeMonitor(localUpToken) }
        if let flagsToken { NSEvent.removeMonitor(flagsToken) }
        if let localFlagsToken { NSEvent.removeMonitor(localFlagsToken) }
    }
}
