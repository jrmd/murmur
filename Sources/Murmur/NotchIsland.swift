import AppKit
import SwiftUI

// MARK: - Model

enum IslandAction: Equatable {
    case openMicrophoneSettings, openSetup
    var label: String {
        self == .openSetup
            ? String(localized: "Open Murmur", comment: "Button in the dictation overlay that brings the app forward.")
            : String(localized: "Open Settings", comment: "Button in the dictation overlay that opens System Settings.")
    }
}

enum IslandPhase: Equatable {
    case hidden
    case listening
    case working(String)
    case pasted(preview: String, app: String?, seconds: Double?, verb: String)
    case error(title: String, message: String, action: IslandAction?)
}

struct NotchMetrics: Equatable {
    var notchWidth: CGFloat = 186
    var height: CGFloat = 37
    var hasNotch = true

    /// Measured from the screen, never hard-coded: the notch is the gap between the two menu-bar clearance areas.
    @MainActor static func measure(_ screen: NSScreen) -> NotchMetrics {
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return NotchMetrics(notchWidth: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top, hasNotch: true)
        }
        let bar = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchMetrics(notchWidth: 110, height: max(24, bar), hasNotch: false)
    }
}

@MainActor
final class IslandModel: ObservableObject {
    @Published var phase: IslandPhase = .hidden
    @Published var metrics = NotchMetrics()

    var size: CGSize {
        let notch = metrics.notchWidth, h = metrics.height
        switch phase {
        case .hidden: return CGSize(width: notch, height: h)
        case .listening: return CGSize(width: notch + 2 * 124, height: h)
        case .working: return CGSize(width: notch + 2 * 92, height: h)
        case .pasted: return CGSize(width: min(notch + 2 * 140, Self.panelWidth), height: h + 38)
        case .error: return CGSize(width: min(notch + 2 * 140, Self.panelWidth), height: h + 46)
        }
    }
    static let panelWidth: CGFloat = 540
}

// MARK: - Presenter

@MainActor
final class OverlayPresenter {
    static let shared = OverlayPresenter()
    private let model = IslandModel()
    private var panel: NSPanel?
    private weak var controller: AppController?
    private var dismissTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    /// The phase VoiceOver last heard, so a repeated update does not repeat the announcement.
    private var announcedKey: String?

    func update(controller: AppController) {
        self.controller = controller
        ensurePanel(controller)
        #if DEBUG
        if debugHold { return }
        #endif
        if controller.isPracticing { hide(); return }
        switch controller.status {
        case .listening: show(.listening)
        case .transcribing: show(.working(String(localized: "Transcribing…", comment: "Overlay label while speech is being turned into text.")))
        case .tidying: show(.working(String(localized: "Tidying…", comment: "Overlay label while the clean-up model rewrites the transcript.")))
        case .error:
            show(errorPhase(controller))
            scheduleDismiss(after: 6)
        case .idle:
            // Pasted and error states keep their own timers; a bare Idle only ends listening/working.
            switch model.phase {
            case .listening, .working: scheduleDismiss(after: 0.45)
            default: break
            }
        case .preparing:
            break // Preparing must not end an active island
        }
    }

    /// Hides the island at once, for a dictation the user abandoned.
    func dismiss() { hide() }

    func showPasted(text: String, appName: String?, seconds: Double?,
                    verb: String = String(localized: "Pasted", comment: "Overlay label after a dictation was pasted into the frontmost app.")) {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        show(.pasted(preview: String(flat.prefix(120)), app: appName, seconds: seconds, verb: verb))
        scheduleDismiss(after: 1.6)
    }

    #if DEBUG
    private var debugHold = false
    func debugShow(_ name: String, controller: AppController) {
        ensurePanel(controller)
        debugHold = true
        switch name {
        case "listening": show(.listening)
        case "working": show(.working("Tidying…"))
        case "pasted": show(.pasted(preview: "Pick up oat milk and book the van MOT for Friday.", app: "Notes", seconds: 0.4, verb: "Pasted"))
        case "error": show(.error(title: "No mic", message: "No microphone found. Pick an input.", action: .openMicrophoneSettings))
        default: break
        }
    }
    #endif

    func perform(_ action: IslandAction) {
        switch action {
        case .openMicrophoneSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
        case .openSetup:
            controller?.showOnboarding = true
        }
        hide()
    }

    // MARK: Internals

    private func errorPhase(_ controller: AppController) -> IslandPhase {
        let message = controller.errorMessage ?? String(localized: "Something went wrong.", comment: "Fallback message in the dictation overlay when no error text is available.")
        let failed = String(localized: "Couldn’t dictate", comment: "Title of the dictation overlay when a dictation failed.")
        guard let kind = controller.lastError?.kind else { return .error(title: failed, message: message, action: nil) }
        switch kind {
        case .microphoneDenied:
            return .error(title: String(localized: "No mic access", comment: "Title of the dictation overlay when microphone permission was refused."),
                          message: String(localized: "Murmur can’t use the microphone.", comment: "Message in the dictation overlay when microphone permission was refused."),
                          action: .openMicrophoneSettings)
        case .noMicrophone:
            return .error(title: String(localized: "No mic", comment: "Title of the dictation overlay when no microphone was found."),
                          message: String(localized: "No microphone found. Pick an input.", comment: "Message in the dictation overlay when no microphone was found."),
                          action: .openMicrophoneSettings)
        case .modelsNotReady:
            return .error(title: String(localized: "Models not ready", comment: "Title of the dictation overlay when the models are still loading."),
                          message: String(localized: "Murmur is still setting up its local models.", comment: "Message in the dictation overlay when the models are still loading."),
                          action: .openSetup)
        case .microphoneChanged:
            return .error(title: String(localized: "Microphone changed", comment: "Title of the dictation overlay when the audio input changed mid-recording."), message: message, action: nil)
        case .busy, .modelChanged, .other:
            return .error(title: failed, message: message, action: nil)
        }
    }

    private func ensurePanel(_ controller: AppController) {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: IslandModel.panelWidth, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar + 2
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.ignoresMouseEvents = true
        p.isMovableByWindowBackground = false
        p.contentView = NSHostingView(rootView: DictationIsland(model: model, controller: controller))
        panel = p
    }

    private func show(_ phase: IslandPhase) {
        guard let panel, let screen = targetScreen() else { return }
        dismissTask?.cancel(); collapseTask?.cancel()
        let metrics = NotchMetrics.measure(screen)
        model.metrics = metrics
        let height = metrics.height + 56
        panel.setFrame(NSRect(x: screen.frame.midX - IslandModel.panelWidth / 2, y: screen.frame.maxY - height, width: IslandModel.panelWidth, height: height), display: false)
        if case .error = phase { panel.ignoresMouseEvents = false } else { panel.ignoresMouseEvents = true }
        if !panel.isVisible { model.phase = .hidden; panel.orderFrontRegardless() }
        if model.phase == .hidden {
            // Let the collapsed shape lay out first so the spring has something to grow from.
            DispatchQueue.main.async { self.model.phase = phase }
        } else {
            model.phase = phase
        }
        announce(phase)
    }

    /// VoiceOver hears the state changes the island shows visually.
    private func announce(_ phase: IslandPhase) {
        let key = phase.contentKey
        guard key != announcedKey else { return }
        announcedKey = key
        switch phase {
        case .hidden: return
        case .listening: announce(String(localized: "Listening", comment: "Dictation state: the microphone is recording."))
        case .working(let label): announce(label.replacingOccurrences(of: "…", with: ""))
        case .pasted(_, _, _, let verb): announce(verb)
        case .error(let title, _, _): announce(title)
        }
    }

    /// Posts an announcement for something the island does not show, such as the recording hitting its limit.
    func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func scheduleDismiss(after seconds: Double) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        dismissTask?.cancel()
        announcedKey = nil
        guard panel?.isVisible == true else { return }
        model.phase = .hidden
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.4))
            guard !Task.isCancelled, let self, self.model.phase == .hidden else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func targetScreen() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
    }
}

// MARK: - Views

private let islandRed = Color(red: 1.0, green: 0.42, blue: 0.40)

struct DictationIsland: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var controller: AppController

    /// Read on each layout pass: the island is small enough that asking the system is cheap.
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        let size = model.size
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 16, bottomTrailingRadius: 16, topTrailingRadius: 0, style: .continuous)
                .fill(Color.black)
                .frame(width: size.width, height: size.height)
                .opacity(model.phase == .hidden && !model.metrics.hasNotch ? 0 : 1)
            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16, style: .continuous))
        }
        .frame(width: IslandModel.panelWidth, height: model.metrics.height + 56, alignment: .top)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.35, dampingFraction: 0.78), value: model.phase)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        let h = model.metrics.height, notch = model.metrics.notchWidth
        Group {
            switch model.phase {
            case .hidden:
                Color.clear
            case .listening:
                row(height: h, notch: notch) {
                    IslandMark()
                    Text("Listening").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                } right: {
                    LiveBars(controller: controller)
                    ListeningTimer(start: controller.listeningStartedAt)
                }
            case .working(let label):
                row(height: h, notch: notch) {
                    IslandSpinner()
                } right: {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.murmurCoral)
                    ShimmerText(text: label)
                }
            case .pasted(let preview, let app, let seconds, let verb):
                VStack(spacing: 0) {
                    row(height: h, notch: notch) {
                        IslandMark()
                    } right: {
                        Text(app.map { "\(verb) · \($0)" } ?? verb).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(LinearGradient(colors: [Color.murmurCoral, Color.murmurCoralDeep], startPoint: .top, endPoint: .bottom))
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        }.frame(width: 18, height: 18)
                        Text(preview).font(.system(size: 13.5)).foregroundStyle(.white).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 6)
                        if let seconds { Text(String(format: "%.1f s", seconds)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.4)) }
                    }
                    .padding(.horizontal, 18).frame(height: 38)
                }
            case .error(let title, let message, let action):
                VStack(spacing: 0) {
                    row(height: h, notch: notch) {
                        Image(systemName: "mic.slash").font(.system(size: 12, weight: .semibold)).foregroundStyle(islandRed)
                        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(islandRed).lineLimit(1)
                    } right: {
                        Text("Murmur").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.45))
                    }
                    HStack(spacing: 10) {
                        Text(message).font(.system(size: 13.5)).foregroundStyle(.white).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        if let action {
                            Button { OverlayPresenter.shared.perform(action) } label: {
                                Text(action.label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 12).frame(height: 26).background(.white.opacity(0.14), in: .capsule)
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 18).frame(height: 46)
                }
            }
        }
        // Content arrives at ~60% of the shape's expansion; it leaves immediately.
        .id(model.phase.contentKey)
        .transition(reduceMotion
            ? .asymmetric(insertion: .opacity.animation(.easeIn(duration: 0.1)), removal: .opacity.animation(.easeOut(duration: 0.08)))
            : .asymmetric(insertion: .opacity.animation(.easeIn(duration: 0.15).delay(0.21)), removal: .opacity.animation(.easeOut(duration: 0.08))))
    }

    private func row<L: View, R: View>(height: CGFloat, notch: CGFloat, @ViewBuilder left: () -> L, @ViewBuilder right: () -> R) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) { left() }.padding(.leading, 12).frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: notch)
            HStack(spacing: 8) { right() }.padding(.trailing, 14).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: height)
    }
}

private extension IslandPhase {
    /// Identity for the content cross-fade; changing text inside one state must not re-trigger it.
    var contentKey: String {
        switch self {
        case .hidden: "hidden"
        case .listening: "listening"
        case .working: "working"
        case .pasted: "pasted"
        case .error: "error"
        }
    }
}

private struct IslandMark: View {
    var body: some View {
        Image("MurmurBrandMark").resizable().interpolation(.high)
            .frame(width: 22, height: 22)
            .shadow(color: Color.murmurCoral.opacity(0.35), radius: 4)
    }
}

private final class Smoother { var value: Float = 0 }

/// 13 coral bars, centre tallest and edges tapering, driven by the mic RMS at 30 fps and smoothed over ~80 ms.
private struct LiveBars: View {
    @ObservedObject var controller: AppController
    @State private var smoother = Smoother()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let level = smooth(Self.debugLevel ?? controller.audioLevel)
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<13, id: \.self) { index in
                    let envelope = 1 - 0.65 * abs(Double(index) - 6) / 6
                    let jitter = 0.78 + 0.22 * sin(t * 9 + Double(index) * 1.3)
                    Capsule().fill(Color.murmurCoral)
                        .frame(width: 3, height: max(3, 3 + 17 * CGFloat(min(1, level * 1.6)) * envelope * jitter))
                }
            }
            .frame(height: 20)
        }
    }

    private static var debugLevel: Float? {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-obIsland") ? 0.6 : nil
        #else
        nil
        #endif
    }

    private func smooth(_ raw: Float) -> Float {
        smoother.value += (raw - smoother.value) * 0.4
        return smoother.value
    }
}

private struct ListeningTimer: View {
    let start: Date?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(start ?? context.date)))
            Text(String(format: "%d:%02d", elapsed / 60, elapsed % 60))
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize()
        }
    }
}

private struct IslandSpinner: View {
    var body: some View {
        Group {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                ring(angle: 0)
            } else {
                TimelineView(.animation) { context in
                    ring(angle: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360)
                }
            }
        }
        .padding(.leading, 6)
    }

    private func ring(angle: Double) -> some View {
        Circle().trim(from: 0, to: 0.75)
            .stroke(Color.murmurCoral, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            .frame(width: 15, height: 15)
            .rotationEffect(.degrees(angle))
    }
}

private struct ShimmerText: View {
    let text: String
    var body: some View {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
        } else {
            TimelineView(.animation) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                Text(text).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LinearGradient(
                        colors: [.white.opacity(0.45), .white, .white.opacity(0.45)],
                        startPoint: UnitPoint(x: phase * 2 - 1, y: 0.5), endPoint: UnitPoint(x: phase * 2, y: 0.5)))
            }
        }
    }
}
