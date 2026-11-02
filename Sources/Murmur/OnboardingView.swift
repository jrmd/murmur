import AppKit
import AVFoundation
import MurmurCore
import SwiftUI

enum SetupStep: Int, CaseIterable {
    case welcome, microphone, accessibility, inputMonitoring, shortcut, models, practice
}

/// Debug-only overrides so every drawn state can be reached without changing real permissions:
/// `-obStep 2 -obState needed|waiting|granted -obModels none|downloading|ready -obPractice listening|result`
private struct DebugPreview {
    static let args = ProcessInfo.processInfo.arguments
    static func value(_ key: String) -> String? {
        #if DEBUG
        guard let i = args.firstIndex(of: key), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
        #else
        return nil
        #endif
    }
    static var step: Int? { value("-obStep").flatMap(Int.init) }
    static var state: String? { value("-obState") }
    static var models: String? { value("-obModels") }
    static var practice: String? { value("-obPractice") }
}

struct OnboardingView: View {
    @ObservedObject var controller: AppController
    let onFinish: () -> Void

    @State private var step: SetupStep
    @State private var accessibilityRequested = false
    @State private var inputRequested = false
    @State private var capturing = false
    @State private var downloadStart: Date?

    init(controller: AppController, onFinish: @escaping () -> Void) {
        self.controller = controller
        self.onFinish = onFinish
        let saved = UserDefaults.standard.object(forKey: "onboardingStep") as? Int
        let start = DebugPreview.step ?? (UserDefaults.standard.bool(forKey: "onboardingFinished") ? nil : saved) ?? Self.firstIncomplete(controller).rawValue
        _step = State(initialValue: SetupStep(rawValue: start) ?? .welcome)
    }

    private static func firstIncomplete(_ c: AppController) -> SetupStep {
        if !c.microphoneGranted { return .microphone }
        if !c.accessibilityGranted { return .accessibility }
        if !c.inputMonitoringGranted { return .inputMonitoring }
        if !c.modelsReady { return .models }
        return .welcome
    }

    // MARK: Derived state (with debug overrides)

    private func permission(_ real: Bool) -> PermissionState {
        switch DebugPreview.state {
        case "needed": .needed
        case "waiting": .waiting
        case "granted": .granted
        default: real ? .granted : .needed
        }
    }
    private var mic: PermissionState { micDenied ? .denied : permission(controller.microphoneGranted) }
    private var micDenied: Bool { DebugPreview.state == nil && controller.microphoneAuthorization == .denied }
    private var accessibility: PermissionState { let s = permission(controller.accessibilityGranted); return s == .needed && accessibilityRequested ? .waiting : s }
    private var inputMonitoring: PermissionState { let s = permission(controller.inputMonitoringGranted); return s == .needed && inputRequested ? .waiting : s }
    private var needsRelaunch: Bool { DebugPreview.state == "granted" ? true : controller.inputNeedsRelaunch }

    private enum ModelsPhase { case notDownloaded, downloading, ready, failed }
    private var modelsPhase: ModelsPhase {
        switch DebugPreview.models {
        case "none": return .notDownloaded
        case "downloading": return .downloading
        case "ready": return .ready
        default: break
        }
        if controller.modelsReady { return .ready }
        if controller.isPreparing { return .downloading }
        if controller.errorMessage != nil { return .failed }
        return .notDownloaded
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case .welcome: welcome
                case .microphone: microphoneStep
                case .accessibility: accessibilityStep
                case .inputMonitoring: inputMonitoringStep
                case .shortcut: shortcutStep
                case .models: modelsStep
                case .practice: practiceStep
                }
            }
            .id(step)
            .transition(.opacity.combined(with: .offset(y: 6)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .frame(width: 760, height: 560)
        .background {
            ZStack {
                RadialGradient(colors: [Color.murmurCoralDeep.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 460)
                RadialGradient(colors: [Color(red: 0.42, green: 0.27, blue: 0.78).opacity(0.20), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 420)
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .tint(.murmurCoral)
        .task {
            while !Task.isCancelled {
                controller.refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: step) { _, value in
            UserDefaults.standard.set(value.rawValue, forKey: "onboardingStep")
            if value == .microphone { controller.openMicrophoneMeter() } else { controller.stopMicrophoneMeter() }
        }
        .onChange(of: controller.isPreparing) { _, preparing in downloadStart = preparing ? Date() : nil }
        .onAppear {
            if step == .microphone { controller.openMicrophoneMeter() }
            UserDefaults.standard.set(step.rawValue, forKey: "onboardingStep")
        }
    }

    private func go(_ target: SetupStep) { withAnimation(.easeInOut(duration: 0.25)) { step = target } }
    private func next() { if let n = SetupStep(rawValue: step.rawValue + 1) { go(n) } }

    // MARK: Footer

    private var footer: some View {
        ZStack {
            Stepper(current: step.rawValue, count: SetupStep.allCases.count)
            HStack {
                if step != .welcome {
                    Button("Back") { if let p = SetupStep(rawValue: step.rawValue - 1) { go(p) } }
                        .buttonStyle(GlassCapsuleStyle())
                }
                Spacer()
                primaryButton
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 76)
    }

    @ViewBuilder private var primaryButton: some View {
        switch step {
        case .welcome:
            PrimaryButton(title: "Get started") { next() }
        case .microphone:
            switch mic {
            case .granted: PrimaryButton(title: "Continue") { next() }
            case .denied: PrimaryButton(title: "Open System Settings", symbol: "gearshape") { openPrivacyPane("Privacy_Microphone") }
            default: PrimaryButton(title: "Allow Microphone", symbol: "mic") { Task { await controller.requestMicrophone() } }
            }
        case .accessibility:
            if accessibility == .granted { PrimaryButton(title: "Continue") { next() } }
            else {
                PrimaryButton(title: "Open System Settings", symbol: "gearshape") {
                    accessibilityRequested = true
                    controller.requestAccessibility()
                    openPrivacyPane("Privacy_Accessibility")
                }
            }
        case .inputMonitoring:
            if inputMonitoring == .granted { PrimaryButton(title: "Continue") { next() } }
            else {
                PrimaryButton(title: "Open System Settings", symbol: "gearshape") {
                    inputRequested = true
                    controller.requestInputMonitoring()
                    openPrivacyPane("Privacy_ListenEvent")
                }
            }
        case .shortcut:
            PrimaryButton(title: "Continue") { controller.saveHotkey(); next() }
        case .models:
            switch modelsPhase {
            case .ready: PrimaryButton(title: "Continue") { next() }
            case .downloading: PrimaryButton(title: "Continue", enabled: false) {}
            case .failed: PrimaryButton(title: "Retry", symbol: "arrow.clockwise") { Task { await controller.prepare() } }
            case .notDownloaded: PrimaryButton(title: "Download models", symbol: "arrow.down.circle") { Task { await controller.prepare() } }
            }
        case .practice:
            PrimaryButton(title: "Finish") {
                controller.finishOnboarding()
                UserDefaults.standard.set(0, forKey: "onboardingStep")
                onFinish()
            }
        }
    }

    // MARK: 1 Welcome

    private var welcome: some View {
        VStack(spacing: 0) {
            AppIconView().frame(width: 104, height: 104)
                .background {
                    Circle().fill(RadialGradient(colors: [.murmurCoral.opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: 78))
                        .frame(width: 170, height: 170).blur(radius: 10)
                }
                .padding(.top, 58)
            Text("Welcome to Murmur").font(.system(size: 32, weight: .bold)).tracking(-0.8).foregroundStyle(OB.text).padding(.top, 8)
            Text("Speak naturally. Murmur transcribes and tidies up your words, then types them into whatever app you’re using.")
                .font(.system(size: 15)).foregroundStyle(OB.secondary).multilineTextAlignment(.center).lineSpacing(3)
                .frame(maxWidth: 520).padding(.top, 10)
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    featureCard("lock.shield", "Private by design", "Speech recognition and clean-up run entirely on this Mac.")
                    featureCard("macwindow", "Works in every app", "Hold your shortcut, speak, let go. The text lands where you’re typing.")
                    featureCard("wifi.slash", "Works offline", "After a one-time model download, no internet needed.")
                }
            }
            .padding(.top, 22).padding(.horizontal, 56)
            Text("Setup takes about two minutes: three permissions, a shortcut and two local models.")
                .font(.system(size: 12.5)).foregroundStyle(OB.tertiary).padding(.top, 22)
        }
    }

    private func featureCard(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            IconChip(symbol: symbol, size: 32).padding(.bottom, 7)
            Text(title).font(.system(size: 14, weight: .semibold)).tracking(-0.1).foregroundStyle(OB.text)
            Text(detail).font(.system(size: 12.5)).foregroundStyle(OB.secondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, minHeight: 145, alignment: .topLeading)
        .obCard()
    }

    // MARK: 2 Microphone

    private var microphoneStep: some View {
        content {
            StepHeader(symbol: "mic", eyebrow: "Step 2 of 7 · Permissions", title: "Microphone", pill: mic.pill)
            Lead("Murmur needs your microphone to hear you while you dictate. It only listens while you hold your dictation shortcut.")
            if mic == .granted {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        IconChip(symbol: "mic")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(controller.inputDeviceName).font(.system(size: 14, weight: .semibold)).foregroundStyle(OB.text)
                            Text("Say something to check the level.").font(.system(size: 12.5)).foregroundStyle(OB.secondary)
                        }
                        Spacer()
                        LevelBars(level: DebugPreview.state == "granted" ? 0.55 : controller.microphoneLevel, count: 14)
                    }
                    .padding(14).obCard()
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(Color.murmurGreen).frame(width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Microphone access granted").font(.system(size: 14, weight: .semibold)).foregroundStyle(OB.text)
                            Text("You can change this any time in System Settings › Privacy & Security › Microphone.").font(.system(size: 12.5)).foregroundStyle(OB.secondary)
                        }
                        Spacer()
                    }
                    .padding(14).obCard()
                }
            } else {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 14) {
                        NumberedStep(number: 1, mark: .current, text: Text("Click ") + Text("Allow Microphone").bold() + Text(" below."))
                        NumberedStep(number: 2, mark: .future, text: Text("macOS shows a prompt. Choose ") + Text("Allow").bold() + Text("."))
                        NumberedStep(number: 3, mark: .future, text: Text("That’s it. Murmur asks once and remembers."))
                        if micDenied {
                            Text("Microphone access was denied. Turn Murmur on in System Settings › Privacy & Security › Microphone.")
                                .font(.system(size: 12.5)).foregroundStyle(OB.amberText).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    permissionPromptIllustration
                }
            }
        }
    }

    private var permissionPromptIllustration: some View {
        VStack(spacing: 8) {
            AppIconView().frame(width: 34, height: 34)
            Text("“Murmur” would like to access the microphone.").font(.system(size: 13, weight: .semibold)).foregroundStyle(OB.text).multilineTextAlignment(.center)
            Text("Murmur listens only while you hold your dictation shortcut.").font(.system(size: 11)).foregroundStyle(OB.secondary).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Text("Don’t Allow").font(.system(size: 12, weight: .medium)).foregroundStyle(OB.text).frame(maxWidth: .infinity).frame(height: 26)
                    .background(OB.text.opacity(0.08), in: .capsule)
                Text("Allow").font(.system(size: 12, weight: .semibold)).foregroundStyle(OB.text).frame(maxWidth: .infinity).frame(height: 26)
                    .background(OB.text.opacity(0.10), in: .capsule)
                    .overlay(Capsule().strokeBorder(Color.murmurCoral, lineWidth: 1.5))
            }
            .padding(.top, 4)
        }
        .padding(16).frame(width: 232)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    // MARK: 3 Accessibility

    private var accessibilityStep: some View {
        content {
            StepHeader(symbol: "accessibility", eyebrow: "Step 3 of 7 · Permissions", title: "Accessibility", pill: accessibility.pill)
            Lead("Accessibility lets Murmur paste your finished dictation into the app you’re using.")
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    NumberedStep(number: 1, mark: accessibility == .needed ? .current : .done, text: Text("Click ") + Text("Open System Settings").bold() + Text("."))
                    NumberedStep(number: 2, mark: accessibility == .needed ? .future : accessibility == .waiting ? .current : .done, text: Text("Find ") + Text("Murmur").bold() + Text(" in the list and turn it on."))
                    NumberedStep(number: 3, mark: accessibility == .granted ? .done : .future, text: Text("Come back here. This window updates on its own."))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SettingsIllustration(pane: "Accessibility", murmurOn: accessibility == .granted, highlight: accessibility != .granted)
            }
        }
    }

    // MARK: 4 Input Monitoring

    private var inputMonitoringStep: some View {
        content {
            StepHeader(symbol: "keyboard", eyebrow: "Step 4 of 7 · Permissions", title: "Input Monitoring", pill: inputMonitoring.pill)
            Lead("Input Monitoring lets Murmur notice your shortcut while another app is in front.")
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    NumberedStep(number: 1, mark: inputMonitoring == .needed ? .current : .done, text: Text("Click ") + Text("Open System Settings").bold() + Text("."))
                    NumberedStep(number: 2, mark: inputMonitoring == .needed ? .future : inputMonitoring == .waiting ? .current : .done, text: Text("Turn on ") + Text("Murmur").bold() + Text(" under Input Monitoring."))
                    NumberedStep(number: 3, mark: inputMonitoring == .granted && needsRelaunch ? .current : inputMonitoring == .granted ? .done : .future, text: Text("Relaunch Murmur").bold() + Text(" so macOS applies the change."))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SettingsIllustration(pane: "Input Monitoring", caption: "Allow the apps below to monitor input from your keyboard.", murmurOn: inputMonitoring == .granted, highlight: inputMonitoring != .granted)
            }
            if inputMonitoring == .granted && needsRelaunch {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .semibold)).foregroundStyle(OB.amberText).frame(width: 24)
                    (Text("One quick relaunch. ").bold() + Text("macOS often needs Murmur to restart before the shortcut works. You’ll come straight back to this step."))
                        .font(.system(size: 12.5)).foregroundStyle(OB.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Relaunch Murmur") { controller.relaunch() }.buttonStyle(GlassCapsuleStyle(small: true))
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Color.murmurAmber.opacity(0.13), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.murmurAmber.opacity(0.25), lineWidth: 1))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.25), value: needsRelaunch)
    }

    // MARK: 5 Shortcut

    private var shortcutStep: some View {
        content {
            StepHeader(symbol: "", customIcon: AnyView(Text("fn").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.murmurCoral)
                .padding(.horizontal, 6).frame(height: 24).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.murmurCoral, lineWidth: 1.6))),
                       eyebrow: "Step 5 of 7 · Shortcut", title: "Choose your shortcut")
            Lead("Pick how you start dictating. You can change this later in Settings.")
            HStack(spacing: 12) {
                modeCard("Hold to talk", "Hold the shortcut while you speak. Let go to paste. Best for quick notes.", "hand.tap", "Hold")
                modeCard("Press to toggle", "Press once to start, again to stop. Best for longer dictation.", "switch.2", "Toggle")
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dictation shortcut").font(.system(size: 14, weight: .semibold)).foregroundStyle(OB.text)
                    Text(capturing ? "Press the key or combination you want…" : "Click Record, then press the key or combination you want.")
                        .font(.system(size: 12.5)).foregroundStyle(OB.secondary)
                }
                Spacer()
                shortcutKeycaps
                VStack(spacing: 6) {
                    Button(capturing ? "Press a key…" : "Record…") { capturing.toggle() }.buttonStyle(GlassCapsuleStyle(small: true))
                    Button("Reset") { capturing = false; controller.hotkeyCode = 63; controller.hotkeyModifiers = Int(NSEvent.ModifierFlags.function.rawValue) }
                        .buttonStyle(GlassCapsuleStyle(small: true))
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14).obCard()
            .background(KeyRecorder(capturing: $capturing, keyCode: $controller.hotkeyCode, modifiers: $controller.hotkeyModifiers))
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(OB.tertiary).padding(.top, 2)
                (Text("fn (") + Text(Image(systemName: "globe")) + Text(") is the default because it rarely clashes with other apps. If it opens the emoji picker, set “Press ") + Text(Image(systemName: "globe")) + Text(" key to” to “Do Nothing” in System Settings › Keyboard."))
                    .font(.system(size: 12.5)).foregroundStyle(OB.tertiary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var shortcutKeycaps: some View {
        let parts = ShortcutLabel.parts(code: controller.hotkeyCode, modifiers: controller.hotkeyModifiers)
        return HStack(spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in Keycap(label: part.label, symbol: part.symbol, active: true) }
        }
    }

    private func modeCard(_ title: String, _ detail: String, _ symbol: String, _ mode: String) -> some View {
        let selected = controller.mode == mode
        return Button { controller.mode = mode } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Color.murmurCoral)
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(OB.text)
                    Spacer()
                    ZStack {
                        Circle().strokeBorder(selected ? .clear : OB.tertiary, lineWidth: 1.5)
                        if selected { Circle().fill(Color.murmurCoral); Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                    }.frame(width: 20, height: 20)
                }
                Text(detail).font(.system(size: 12.5)).foregroundStyle(OB.secondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16).frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
            .obCard(tint: selected ? Color.murmurCoral.opacity(0.14) : nil)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(selected ? Color.murmurCoral : .clear, lineWidth: 1.5))
            .shadow(color: selected ? Color.murmurCoral.opacity(0.22) : .clear, radius: 8)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: selected)
    }

    // MARK: 6 Models

    private var modelsStep: some View {
        let pill: PillKind = modelsPhase == .ready ? .ready : modelsPhase == .downloading ? .downloading : .notDownloaded
        let desc = controller.prepareDescription
        let cleanup = controller.cleanupModel
        let parakeetDone = modelsPhase == .ready || desc.contains(cleanup.shortName)
        let cleanupActive = modelsPhase == .downloading && desc.contains(cleanup.shortName)
        let debugFraction: Double? = DebugPreview.models == "downloading" ? 0.64 : nil
        let fraction = debugFraction ?? controller.prepareFraction
        return content(spacing: 12) {
            StepHeader(symbol: "arrow.down.circle", eyebrow: "Step 6 of 7 · Local models", title: "Download models", pill: pill)
            Lead("Choose your models, then download them. They live on your Mac, so dictation works offline.")
            modelPickers
            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    ModelRow(symbol: "waveform", name: controller.speechModel.shortName, detail: "Speech recognition", size: "~460 MB",
                             state: parakeetDone ? .ready : modelsPhase == .downloading ? .downloading(fraction, started: downloadStart) : .idle)
                    ModelRow(symbol: "sparkles", name: cleanup.displayName, detail: "Clean-up: punctuation, filler words, corrections",
                             size: ByteCountFormatter.string(fromByteCount: cleanup.approximateBytes, countStyle: .file),
                             state: modelsPhase == .ready ? .ready : cleanupActive ? .downloading(nil, started: nil) : modelsPhase == .downloading ? .queued : .idle)
                }
            }
            if modelsPhase == .failed, let message = controller.errorMessage {
                HStack(spacing: 10) {
                    Image(systemName: isOffline(message) ? "wifi.slash" : "exclamationmark.triangle").foregroundStyle(OB.amberText)
                    Text(isOffline(message) ? "You appear to be offline. Connect to the internet and retry." : message)
                        .font(.system(size: 12.5)).foregroundStyle(OB.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Color.murmurAmber.opacity(0.13), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.murmurAmber.opacity(0.25), lineWidth: 1))
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield").font(.system(size: 14)).foregroundStyle(Color.murmurCoral)
                    (Text("On-device and private. ").bold().foregroundStyle(OB.text) + Text("Your voice and text never leave this Mac.").foregroundStyle(OB.secondary))
                        .font(.system(size: 14))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).frame(height: 36)
                .background(Color.murmurCoral.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.murmurCoral.opacity(0.25), lineWidth: 1))
            }
        }
    }

    private var modelPickers: some View {
        let locked = modelsPhase == .downloading
        return VStack(alignment: .leading, spacing: 10) {
            modelPickerRow("Speech model", summary: controller.speechModel.detail,
                           selection: Binding(get: { controller.speechModel }, set: { model in Task { await controller.chooseSpeechModel(model) } }),
                           options: SpeechModel.allCases, label: \.shortName, locked: locked)
            Divider().opacity(0.5)
            modelPickerRow("Clean-up model", summary: controller.cleanupModel.summary,
                           selection: Binding(get: { controller.cleanupModel }, set: { model in Task { await controller.chooseCleanupModel(model) } }),
                           options: CleanupModel.allCases, label: \.displayName, locked: locked)
        }
        .padding(.horizontal, 18).padding(.vertical, 11).obCard()
    }

    private func modelPickerRow<Model: Hashable & Identifiable>(
        _ title: String, summary: String, selection: Binding<Model>, options: [Model], label: KeyPath<Model, String>, locked: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 16) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(OB.text)
                Spacer(minLength: 8)
                Picker(title, selection: selection) {
                    ForEach(options) { Text($0[keyPath: label]).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 250)
                .disabled(locked)
            }
            Text(summary).font(.system(size: 12.5)).foregroundStyle(OB.secondary)
        }
    }

    private func isOffline(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("offline") || m.contains("internet") || m.contains("network connection") || m.contains("could not connect")
    }

    // MARK: 7 Practice

    private var practiceStep: some View {
        let listening = DebugPreview.practice == "listening" || controller.statusText == "Listening"
        let working = controller.statusText == "Transcribing" || controller.statusText == "Tidying"
        let result: DictationResultView? = {
            if DebugPreview.practice == "result" {
                return DictationResultView(final: "Can you pick up two oat milks and some dog food on the way home?",
                                           raw: "um can you pick up oat milk no wait two oat milks and uh some dog food on the way home", seconds: 0.4)
            }
            guard let r = controller.lastResult, !listening, !working else { return nil }
            return DictationResultView(final: r.final, raw: r.raw, seconds: controller.cleanupDuration)
        }()
        let shortcut = ShortcutLabel.parts(code: controller.hotkeyCode, modifiers: controller.hotkeyModifiers).map(\.label).joined(separator: " ")
        let instruction = controller.mode == "Toggle"
            ? Text("Give it a go. Press ") + Text(shortcut).bold() + Text(" to start, say something, then press it again.")
            : Text("Give it a go. Hold ") + Text(shortcut).bold() + Text(", say something, then let go.")
        return content {
            StepHeader(symbol: "checkmark.seal", eyebrow: "Step 7 of 7 · Try it", title: "You’re all set")
            Lead(instruction)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("PRACTICE AREA").font(.system(size: 12, weight: .semibold)).tracking(0.6).foregroundStyle(OB.tertiary)
                    Spacer()
                    if let seconds = result?.seconds {
                        Label("Cleaned up in \(String(format: "%.1f", seconds)) s", systemImage: "sparkles")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(OB.coralText)
                            .padding(.horizontal, 10).frame(height: 24).background(Color.murmurCoral.opacity(0.16), in: .capsule)
                    }
                }
                if let result {
                    (Text(result.final) + Text(" ").foregroundStyle(Color.murmurCoral)).font(.system(size: 16)).tracking(-0.15).foregroundStyle(OB.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(result.youSaid).font(.system(size: 13)).foregroundStyle(OB.tertiary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(listening ? "Listening…" : working ? "Cleaning up…" : "Your dictated text will appear here.")
                        .font(.system(size: 16)).foregroundStyle(OB.tertiary)
                }
            }
            .padding(18).frame(maxWidth: .infinity, minHeight: 134, maxHeight: 134, alignment: .topLeading)
            .overlay(alignment: .bottom) {
                if listening {
                    ListeningHUD(level: DebugPreview.practice == "listening" ? 0.6 : controller.audioLevel, label: controller.mode == "Toggle" ? "Listening · press again to paste" : "Listening · release to paste")
                        .padding(.bottom, 14).transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .obCard()
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(listening ? Color.murmurCoral : .clear, lineWidth: 1.5))
            .animation(.easeOut(duration: 0.2), value: listening)
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    tip(AnyView(Image("MenuBarIcon").resizable().renderingMode(.template).frame(width: 16, height: 16).foregroundStyle(Color.murmurCoral)), "Murmur lives in your menu bar", "Settings, history and models are there.")
                    tip(AnyView(Text("fn").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.murmurCoral)), "Hold \(shortcut) anywhere", "Mail, Slack, Notes, your code editor…")
                }
            }
        }
    }

    private func tip(_ icon: AnyView, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            icon.frame(width: 30, height: 30).background(Color.murmurCoral.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(OB.text)
                Text(detail).font(.system(size: 12.5)).foregroundStyle(OB.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).obCard()
    }

    // MARK: Shared

    @ViewBuilder private func content<Content: View>(spacing: CGFloat = 16, @ViewBuilder _ body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: spacing) { body() }
            .padding(.horizontal, 56).padding(.top, 52)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}

private enum PermissionState {
    case needed, waiting, granted, denied
    var pill: PillKind {
        switch self {
        case .needed: .needed
        case .waiting: .waiting
        case .granted: .granted
        case .denied: .denied
        }
    }
}

// MARK: - Model row

private struct ModelRow: View {
    enum RowState { case idle, queued, downloading(Double?, started: Date?), ready }
    let symbol: String
    let name: String
    let detail: String
    let size: String
    let state: RowState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                IconChip(symbol: symbol, size: 36, radius: 11)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(OB.text)
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(OB.secondary)
                }
                Spacer()
                Text(size).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(OB.tertiary)
            }
            switch state {
            case .idle:
                EmptyView()
            case .queued:
                bar(value: 0, tint: .clear)
                Text("Queued. Starts after Parakeet.").font(.system(size: 12)).foregroundStyle(OB.tertiary)
            case .downloading(let fraction, let started):
                if let fraction {
                    bar(value: fraction, tint: .murmurCoral, gradient: true)
                    HStack {
                        Text("\(Int(fraction * 100))% of \(size)").contentTransition(.numericText()).font(.system(size: 12).monospacedDigit()).foregroundStyle(OB.tertiary)
                        Spacer()
                        if let eta = eta(fraction: fraction, started: started) { Text(eta).font(.system(size: 12)).foregroundStyle(OB.tertiary) }
                    }
                } else {
                    IndeterminateBar()
                    Text("Downloading and loading…").font(.system(size: 12)).foregroundStyle(OB.tertiary)
                }
            case .ready:
                bar(value: 1, tint: .murmurGreen)
                HStack {
                    Label("Ready", systemImage: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(OB.greenText)
                    Spacer()
                    Text("Stored on this Mac").font(.system(size: 12)).foregroundStyle(OB.tertiary)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .obCard()
        .animation(.easeOut(duration: 0.25), value: String(describing: state))
    }

    private func bar(value: Double, tint: Color, gradient: Bool = false) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(OB.track)
                if value > 0 {
                    Capsule().fill(gradient ? AnyShapeStyle(OB.progressGradient) : AnyShapeStyle(tint))
                        .frame(width: max(6, proxy.size.width * value))
                }
            }
        }
        .frame(height: 6)
    }

    private func eta(fraction: Double, started: Date?) -> String? {
        guard let started, fraction > 0.03, fraction < 1 else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        let remaining = elapsed / fraction * (1 - fraction)
        return remaining < 60 ? "About \(max(5, Int(remaining / 5) * 5)) seconds left" : "About \(Int((remaining / 60).rounded(.up))) min left"
    }
}

private struct IndeterminateBar: View {
    @State private var phase = false
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(OB.track)
                Capsule().fill(OB.progressGradient).frame(width: proxy.size.width * 0.3)
                    .offset(x: phase ? proxy.size.width * 0.7 : 0)
            }
        }
        .frame(height: 6).clipShape(Capsule())
        .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { phase = true } }
    }
}

// MARK: - Practice result

private struct DictationResultView {
    let final: String
    let raw: String
    let seconds: TimeInterval?

    /// “You said: …” with words the clean-up removed struck through.
    var youSaid: AttributedString {
        func norm(_ s: Substring) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let rawWords = raw.split(separator: " ")
        let finalWords = final.split(separator: " ").map(norm)
        let removed = Set(finalWords.difference(from: rawWords.map(norm)).removals.compactMap { change -> Int? in
            if case .remove(let offset, _, _) = change { return offset } else { return nil }
        })
        var out = AttributedString("You said: “")
        for (index, word) in rawWords.enumerated() {
            var piece = AttributedString(String(word) + (index < rawWords.count - 1 ? " " : ""))
            if removed.contains(index) { piece.strikethroughStyle = .single }
            out += piece
        }
        out += AttributedString("”")
        return out
    }
}

// MARK: - Shortcut labels and recorder

enum ShortcutLabel {
    struct Part { let label: String; let symbol: String? }

    static func parts(code: Int, modifiers: Int) -> [Part] {
        if code == 63 { return [Part(label: "fn", symbol: "globe")] }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        var parts: [Part] = []
        if flags.contains(.control) { parts.append(Part(label: "⌃", symbol: nil)) }
        if flags.contains(.option) { parts.append(Part(label: "⌥", symbol: nil)) }
        if flags.contains(.shift) { parts.append(Part(label: "⇧", symbol: nil)) }
        if flags.contains(.command) { parts.append(Part(label: "⌘", symbol: nil)) }
        parts.append(Part(label: keyName(code), symbol: nil))
        return parts
    }

    private static func keyName(_ code: Int) -> String {
        let names: [Int: String] = [
            49: "Space", 36: "Return", 48: "Tab", 53: "Esc", 51: "Delete", 76: "Enter", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
            45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
            27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 42: "\\", 50: "`",
        ]
        return names[code] ?? "Key \(code)"
    }
}

struct KeyRecorder: NSViewRepresentable {
    @Binding var capturing: Bool
    @Binding var keyCode: Int
    @Binding var modifiers: Int

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onKey = { code, flags in keyCode = code; modifiers = flags; capturing = false }
        view.onFn = { keyCode = 63; modifiers = Int(NSEvent.ModifierFlags.function.rawValue); capturing = false }
        return view
    }
    func updateNSView(_ view: RecorderView, context: Context) {
        view.capturing = capturing
        if capturing { DispatchQueue.main.async { view.window?.makeFirstResponder(view) } }
    }

    final class RecorderView: NSView {
        var capturing = false
        var onKey: ((Int, Int) -> Void)?
        var onFn: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            guard capturing else { return }
            onKey?(Int(event.keyCode), Int(event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.function).rawValue))
        }
        override func flagsChanged(with event: NSEvent) {
            guard capturing, event.keyCode == 63, event.modifierFlags.contains(.function) else { return }
            onFn?()
        }
    }
}
