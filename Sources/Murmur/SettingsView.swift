import AppKit
import SwiftUI
import MurmurCore
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var updates: UpdateController
    @State private var tab: Int = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-obTab"), args.indices.contains(i + 1), let n = Int(args[i + 1]) { return n }
        #endif
        return 0
    }()

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(controller: controller)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            ModelsSettings(controller: controller)
                .tabItem { Label("Models", systemImage: "cpu") }.tag(1)
            DictionarySettings(store: controller.dictionary)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }.tag(2)
            AboutSettings(updates: updates)
                .tabItem { Label("About", systemImage: "info.circle") }.tag(3)
        }
        .tint(.murmurCoral)
        .frame(width: 640)
    }
}

// MARK: - Shared pieces

private struct SettingLabel: View {
    let title: LocalizedStringKey
    var subtitle: Text?

    init(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
        self.title = title
        self.subtitle = subtitle.map { Text($0) }
    }

    /// For a value that must not be looked up, such as a folder path.
    init(title: LocalizedStringKey, verbatimSubtitle: String) {
        self.title = title
        self.subtitle = Text(verbatim: verbatimSubtitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let subtitle { subtitle.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

private struct StatusText: View {
    let granted: Bool
    var body: some View {
        Label("Granted", systemImage: "circle.fill")
            .labelStyle(DotLabelStyle())
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(OB.greenText)
    }
}

private struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            Circle().fill(Color.murmurGreen).frame(width: 7, height: 7)
            configuration.title
        }
    }
}

private func openPane(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var controller: AppController
    @State private var capturing = false
    @State private var capturingPaste = false
    @State private var pasteHint: LocalizedStringKey?
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Dictation shortcut") {
                    HStack(spacing: 8) {
                        ShortcutField(capturing: $capturing, keyCode: $controller.hotkeyCode, modifiers: $controller.hotkeyModifiers)
                        ResetShortcutButton(title: "Reset to fn") {
                            capturing = false
                            controller.hotkeyCode = AppController.defaultHotkeyCode
                            controller.hotkeyModifiers = AppController.defaultHotkeyModifiers
                        }
                    }
                }
                LabeledContent {
                    Picker("Mode", selection: $controller.mode) {
                        Text("Hold to dictate").tag(DictationMode.hold)
                        Text("Press to toggle").tag(DictationMode.toggle)
                    }.labelsHidden().pickerStyle(.menu).fixedSize()
                } label: {
                    SettingLabel(title: "Mode", subtitle: controller.mode == .toggle ? "Press once to start, again to stop." : "Hold the key while you speak, let go to paste.")
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        ShortcutField(capturing: $capturingPaste, keyCode: $controller.pasteLastKeyCode, modifiers: $controller.pasteLastModifiers,
                                      validate: ShortcutLabel.isValidPasteShortcut,
                                      onRejected: { pasteHint = "Hold ⌘, ⌥ or ⌃ with another key." })
                        ResetShortcutButton(title: "Reset to ⌥⇧V") {
                            capturingPaste = false
                            controller.pasteLastKeyCode = Int(PasteKeyCode.current())
                            controller.pasteLastModifiers = Int(NSEvent.ModifierFlags.option.union(.shift).rawValue)
                        }
                    }
                } label: {
                    SettingLabel(title: "Paste last dictation", subtitle: pasteHint ?? "Pastes your last dictation again, without recording.")
                }
            } header: { Text("Shortcut") } footer: {
                Text("Changes save automatically. Murmur listens for the shortcut even when it’s in the background.")
            }

            Section("Output") {
                Toggle(isOn: $controller.cleanupEnabled) { SettingLabel(title: "Clean up dictation", subtitle: "Removes filler words and fixes punctuation, on your Mac.") }
                LabeledContent("After dictating") {
                    Picker("After dictating", selection: $controller.outputMode) {
                        Text("Paste into the active app").tag(OutputMode.paste)
                        Text("Copy to clipboard only").tag(OutputMode.copy)
                    }.labelsHidden().pickerStyle(.menu).fixedSize()
                }
                Toggle(isOn: $controller.playSounds) { SettingLabel(title: "Play sounds", subtitle: "A soft tick when Murmur starts and stops listening.") }
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { value in controller.setLaunchAtLogin(value); launchAtLogin = controller.launchAtLogin }))
            }

            Section("Permissions") {
                PermissionRow(symbol: "mic.fill", colors: [.murmurCoral, .murmurCoralDeep], title: "Microphone", subtitle: "Hear what you say.", granted: controller.microphoneGranted) {
                    if controller.microphoneAuthorization == .denied { openPane("Privacy_Microphone") } else { Task { await controller.requestMicrophone() } }
                }
                PermissionRow(symbol: "accessibility", colors: [Color(red: 0.36, green: 0.62, blue: 1), Color(red: 0.2, green: 0.4, blue: 0.95)], title: "Accessibility", subtitle: "Paste text into other apps.", granted: controller.accessibilityGranted) {
                    controller.requestAccessibility(); openPane("Privacy_Accessibility")
                }
                PermissionRow(symbol: "keyboard", colors: [Color(red: 0.62, green: 0.48, blue: 1), Color(red: 0.45, green: 0.3, blue: 0.9)], title: "Input Monitoring", subtitle: "Notice when you hold the \(shortcutName) key.", granted: controller.inputMonitoringGranted) {
                    controller.requestInputMonitoring(); openPane("Privacy_ListenEvent")
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 640)
        .onAppear { launchAtLogin = controller.launchAtLogin; controller.refreshPermissions() }
        .onChange(of: controller.hotkeyCode) { _, _ in controller.saveHotkey() }
        .onChange(of: controller.hotkeyModifiers) { _, _ in controller.saveHotkey() }
        .onChange(of: controller.mode) { _, _ in controller.saveHotkey() }
        .onChange(of: capturingPaste) { _, on in if on { pasteHint = nil } }
        .onChange(of: controller.pasteLastKeyCode) { _, _ in pasteHint = nil }
    }

    private var shortcutName: String { ShortcutLabel.parts(code: controller.hotkeyCode, modifiers: controller.hotkeyModifiers).map(\.label).joined() }
}

/// Keycaps that turn into a recorder on click; Esc cancels without changing the shortcut.
private struct ShortcutField: View {
    @Binding var capturing: Bool
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    /// Rejects a capture without changing the shortcut, so the user can try again.
    var validate: ((Int, Int) -> Bool)?
    var onRejected: (() -> Void)?

    var body: some View {
        Button { capturing.toggle() } label: {
            HStack(spacing: 8) {
                if capturing { Text("Press a key…").foregroundStyle(Color.murmurCoral) }
                else {
                    ForEach(Array(ShortcutLabel.parts(code: keyCode, modifiers: modifiers).enumerated()), id: \.offset) { _, part in
                        HStack(spacing: 4) {
                            Text(part.label).font(.system(size: 12, weight: .semibold))
                            if let symbol = part.symbol { Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary).accessibilityHidden(true) }
                        }
                        .padding(.horizontal, 7).frame(height: 22)
                        .background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    Text("Click to record").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6).frame(height: 28)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(capturing ? Color.murmurCoral : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(capturing ? "Recording shortcut, press a key" : "Record shortcut")
        .accessibilityValue(ShortcutLabel.parts(code: keyCode, modifiers: modifiers).map(\.label).joined())
        .help(capturing ? "Press the key or combination you want. Esc cancels." : "Click, then press the key or combination you want.")
        .background(KeyRecorder(capturing: $capturing, keyCode: $keyCode, modifiers: $modifiers, validate: validate, onRejected: onRejected))
    }
}

private struct ResetShortcutButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.small)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct PermissionRow: View {
    let symbol: String
    let colors: [Color]
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            SettingLabel(title: title, subtitle: subtitle)
            Spacer()
            if granted { StatusText(granted: true) }
            else { PrimaryButton(title: "Grant…", action: action).controlSize(.small).scaleEffect(0.86) }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Models

private struct ModelsSettings: View {
    @ObservedObject var controller: AppController
    @State private var confirm: Removal?
    #if DEBUG
    @State private var editingCustom = ProcessInfo.processInfo.arguments.contains("-obCustomSheet")
    #else
    @State private var editingCustom = false
    #endif

    private enum Removal: Identifiable {
        case speech(SpeechModel), cleanup(CleanupModel)
        var id: String { switch self { case .speech(let m): m.rawValue; case .cleanup(let m): m.rawValue } }
    }

    var body: some View {
        let _ = controller.storageRevision
        Form {
            Section("Speech recognition") {
                ForEach(SpeechModel.allCases) { model in
                    let preparing = controller.isPreparing && model == controller.speechModel
                    ModelLine(
                        symbol: "waveform", tint: model == .parakeetV3 ? .murmurCoral : .gray,
                        title: model.displayName,
                        detail: [model.detail, sizeText(installed: model.isInstalled, bytes: model.installedBytes, approximate: model.approximateBytes), model == controller.speechModel && model.isInstalled ? inUse : nil].compactMap { $0 }.joined(separator: " · "),
                        state: state(installed: model.isInstalled, active: model == controller.speechModel),
                        busy: controller.isPreparing,
                        progress: preparing ? controller.prepareFraction : nil,
                        note: preparing ? controller.prepareDescription : nil,
                        cancel: preparing ? { controller.cancelPreparing() } : nil,
                        primary: { Task { await controller.selectSpeechModel(model) } },
                        remove: { confirm = .speech(model) })
                }
            }
            Section {
                ForEach(CleanupModel.builtIn) { model in
                    let active = model == controller.cleanupModel
                    let preparing = controller.isPreparing && controller.prepareDescription.contains(model.shortName)
                    ModelLine(
                        symbol: "sparkles", tint: model == .murmurClean ? .murmurCoral : Color(red: 0.45, green: 0.4, blue: 1),
                        title: model.displayName,
                        detail: [model.detail, sizeText(installed: model.isInstalled, bytes: model.installedBytes, approximate: model.approximateBytes), active && model.isInstalled ? inUse : nil].compactMap { $0 }.joined(separator: " · "),
                        state: state(installed: model.isInstalled, active: active),
                        busy: preparing, locked: controller.isPreparing,
                        progress: preparing ? controller.prepareFraction : nil,
                        note: preparing ? controller.prepareDescription : nil,
                        cancel: preparing ? { controller.cancelPreparing() } : nil,
                        primary: { Task { await controller.selectCleanupModel(model) } },
                        remove: { confirm = .cleanup(model) })
                }
                customRow
                if controller.cleanupModel.supportsLevels {
                    LabeledContent {
                        Picker("Strictness", selection: $controller.cleanupLevel) {
                            ForEach(CleanupLevel.allCases) { Text($0.displayName).tag($0) }
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 220)
                    } label: {
                        SettingLabel(title: "Strictness", verbatimSubtitle: controller.cleanupLevel.summary)
                    }
                }
            } header: { Text("Clean-up") } footer: { Text(controller.cleanupModel.summary) }
            Section("Storage") {
                LabeledContent {
                    Button("Show in Finder") { reveal(ModelStorage.speechFolder) }.controlSize(.small)
                } label: { SettingLabel(title: "Speech models", verbatimSubtitle: ModelStorage.speechFolder.path.abbreviatingHome) }
                LabeledContent {
                    Button("Show in Finder") { reveal(ModelStorage.tidyFolder) }.controlSize(.small)
                } label: { SettingLabel(title: "Clean-up model", verbatimSubtitle: ModelStorage.tidyFolder.path.abbreviatingHome) }
                LabeledContent("Space used") { Text(ByteCountFormatter.string(fromByteCount: ModelStorage.totalBytesUsed, countStyle: .file)).foregroundStyle(.secondary).monospacedDigit() }
            }
            if let error = controller.errorMessage, !controller.isPreparing {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(OB.amberText).font(.callout) }
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .sheet(isPresented: $editingCustom) { CustomCleanupSheet(controller: controller, existing: controller.customCleanup) }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                let item = confirm; confirm = nil
                Task { switch item { case .speech(let m): await controller.removeSpeechModel(m); case .cleanup(let m): await controller.removeCleanupModel(m); case nil: break } }
            }
        } message: { Text("You can download it again at any time. Dictation won’t work until the models are back.") }
    }

    @ViewBuilder private var customRow: some View {
        let model = CleanupModel.custom
        if controller.customCleanup != nil {
            let active = model == controller.cleanupModel
            let preparing = controller.isPreparing && controller.prepareDescription.contains(model.shortName)
            ModelLine(
                symbol: "slider.horizontal.3", tint: .orange,
                title: model.displayName,
                detail: [model.detail, sizeText(installed: model.isInstalled, bytes: model.installedBytes, approximate: model.approximateBytes), active && model.isInstalled ? inUse : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                state: state(installed: model.isInstalled, active: active),
                busy: preparing, locked: controller.isPreparing,
                progress: preparing ? controller.prepareFraction : nil,
                note: preparing ? controller.prepareDescription : nil,
                cancel: preparing ? { controller.cancelPreparing() } : nil,
                primary: { Task { await controller.selectCleanupModel(model) } },
                remove: { confirm = .cleanup(model) },
                edit: { editingCustom = true })
        } else {
            LabeledContent {
                Button("Choose…") { editingCustom = true }.controlSize(.small).disabled(controller.isPreparing)
            } label: {
                SettingLabel(title: "Custom model", subtitle: "Run any GGUF model from Hugging Face with your own prompt, for example one that covers more languages.")
            }
        }
    }

    private var confirmTitle: Text {
        switch confirm {
        case .speech(let m): Text("Remove \(m.displayName)?")
        case .cleanup(let m): Text("Remove \(m.displayName)?")
        case nil: Text(verbatim: "")
        }
    }

    /// The badge on the row of the model dictation currently uses.
    private var inUse: String { String(localized: "In use", comment: "Badge on the model row that dictation is currently using.") }

    private func state(installed: Bool, active: Bool) -> ModelLine.State { installed ? (active ? .ready : .installed) : .missing }

    private func sizeText(installed: Bool, bytes: Int64, approximate: Int64) -> String {
        let value = installed && bytes > 0 ? bytes : approximate
        guard value > 0 else { return "" }
        return (installed ? "" : "~") + ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func reveal(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private extension String {
    var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }
}

private struct ModelLine: View {
    enum State { case ready, installed, missing }
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let state: State
    let busy: Bool
    /// Disables the buttons without showing progress, for rows other than the one being prepared.
    var locked = false
    let progress: Double?
    /// Shown under the row while it is being prepared.
    var note: String?
    /// Shown on the busy row so a long download can be stopped.
    var cancel: (() -> Void)?
    let primary: () -> Void
    let remove: () -> Void
    var edit: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if busy {
                    if state != .ready || progress != nil {
                        ProgressView(value: progress).progressViewStyle(.linear).tint(.murmurCoral).frame(maxWidth: 220)
                            .padding(.top, 2)
                    }
                    if let note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if let cancel, busy { Button("Cancel", action: cancel).controlSize(.small) }
            if let edit { Button("Edit…", action: edit).controlSize(.small).disabled(busy || locked) }
            switch state {
            case .ready:
                StatusPill(kind: .ready)
                Button("Remove", action: remove).controlSize(.small).disabled(busy || locked)
            case .installed:
                Button("Use", action: primary).controlSize(.small).disabled(busy || locked)
                Button("Remove", action: remove).controlSize(.small).disabled(busy || locked)
            case .missing:
                PrimaryButton(title: "Download", enabled: !(busy || locked), action: primary).scaleEffect(0.86)
            }
        }
    }
}

// MARK: - Dictionary

private struct DictionarySettings: View {
    @ObservedObject var store: DictionaryStore
    @State private var search = ""
    @State private var selection: UUID?
    @FocusState private var focused: UUID?

    private var filtered: [DictionaryEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? store.entries : store.entries.filter { $0.heard.lowercased().contains(q) || $0.replacement.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = store.persistenceError { persistenceBanner(error) }
            HStack(alignment: .top) {
                Text("Fix names and jargon Murmur mishears.\nReplacements run on your Mac before text is pasted.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary).accessibilityHidden(true)
                    TextField("Search", text: $search).textFieldStyle(.plain).accessibilityLabel("Search dictionary")
                }
                .padding(.horizontal, 10).frame(width: 180, height: 26)
                .background(.primary.opacity(0.06), in: .capsule)
            }
            VStack(spacing: 0) {
                if store.entries.isEmpty { emptyState } else { table }
                Divider().opacity(0.5)
                toolbar
            }
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(OB.cardStroke, lineWidth: 1))
            Text("Match case keeps your capitals exactly. Use ••• to import a list (CSV or JSON) or export it as CSV.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(height: 540)
    }

    /// A dictionary that could not be read or written stays visible until the next successful save.
    private func persistenceBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(OB.amberText).accessibilityHidden(true)
            Text(message).font(.callout).foregroundStyle(OB.amberText).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.murmurAmber.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.murmurAmber.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Heard").frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 16)
                Text("Replace with").frame(maxWidth: .infinity, alignment: .leading)
                Text("Match case").frame(width: 82)
                Text("On").frame(width: 36)
            }
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 14).frame(height: 28)
            Divider().opacity(0.5)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { entry in row(entry) }
                    if filtered.isEmpty { Text("No matches").font(.callout).foregroundStyle(.tertiary).padding(24) }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func row(_ entry: DictionaryEntry) -> some View {
        let selected = selection == entry.id
        let name = entry.heard.isEmpty ? String(localized: "this word", comment: "Stands in for a dictionary entry's word in accessibility labels when the field is empty.") : entry.heard
        return HStack(spacing: 8) {
            TextField("heard", text: bind(entry, \.heard)).textFieldStyle(.plain).font(.system(size: 12.5, design: .monospaced))
                .focused($focused, equals: entry.id).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Heard")
            Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 16).accessibilityHidden(true)
            TextField("replacement", text: bind(entry, \.replacement)).textFieldStyle(.plain).font(.system(size: 13))
                .focused($focused, equals: entry.id).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Replace with")
            Toggle(isOn: bind(entry, \.caseSensitive)) { EmptyView() }.toggleStyle(.checkbox).labelsHidden().frame(width: 82)
                .accessibilityLabel("Match case for \(name)")
            Toggle(isOn: bind(entry, \.enabled)) { EmptyView() }.toggleStyle(.checkbox).labelsHidden().frame(width: 36)
                .accessibilityLabel("Enabled for \(name)")
        }
        .padding(.horizontal, 14).frame(height: 30)
        .background(selected ? Color.murmurCoral.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { selection = entry.id }
        .opacity(entry.enabled ? 1 : 0.6)
        // Clicking into a field never reaches the row's tap gesture, so focus has to select the row too.
        .onChange(of: focused) { _, id in if id == entry.id { selection = entry.id } }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "character.book.closed").font(.system(size: 22)).foregroundStyle(Color.murmurCoral)
                .frame(width: 56, height: 56).background(Color.murmurCoral.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
            Text("No words yet").font(.system(size: 15, weight: .semibold))
            Text("Add names, brands and jargon that come out wrong,\nand Murmur will swap them in every time.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                example("jerome duncan", "Jerome Duncan"); example("g p u i", "GPUI")
            }.padding(.top, 2)
            HStack(spacing: 8) {
                PrimaryButton(title: "Add Word", symbol: "plus") { addWord() }.scaleEffect(0.9)
                Button("Import…") { importList() }.buttonStyle(GlassCapsuleStyle(small: true))
            }.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func example(_ heard: String, _ replacement: String) -> some View {
        HStack(spacing: 5) {
            Text(heard).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
            Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary).accessibilityHidden(true)
            Text(replacement).font(.system(size: 11.5, weight: .semibold))
        }
        .padding(.horizontal, 9).frame(height: 24).background(.primary.opacity(0.06), in: .capsule)
        .accessibilityElement(children: .combine)
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            Button { addWord() } label: { Image(systemName: "plus").frame(width: 28, height: 24).contentShape(Rectangle()) }
                .accessibilityLabel("Add word").help("Add word")
            Button { removeSelected() } label: { Image(systemName: "minus").frame(width: 28, height: 24).contentShape(Rectangle()) }
                .accessibilityLabel("Remove selected word").help("Remove selected word").disabled(selection == nil)
            Menu {
                Button("Import…") { importList() }
                Button("Export…") { exportList() }.disabled(store.entries.isEmpty)
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 24).contentShape(Rectangle()) }
                .menuStyle(.button).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Import or export").help("Import or export")
            Spacer()
            Text("\(store.entries.count) words").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .padding(.horizontal, 10).frame(height: 30)
    }

    // MARK: Actions

    private func bind<T>(_ entry: DictionaryEntry, _ keyPath: WritableKeyPath<DictionaryEntry, T>) -> Binding<T> {
        Binding(
            get: { store.entries.first(where: { $0.id == entry.id })?[keyPath: keyPath] ?? entry[keyPath: keyPath] },
            set: { value in
                guard var current = store.entries.first(where: { $0.id == entry.id }) else { return }
                current[keyPath: keyPath] = value
                store.update(current)
            })
    }

    private func addWord() {
        search = ""
        let entry = DictionaryEntry(heard: "", replacement: "")
        store.add(entry)
        selection = entry.id
        DispatchQueue.main.async { focused = entry.id }
    }

    private func removeSelected() {
        guard let id = selection else { return }
        store.remove(id: id)
        selection = nil
    }

    private func importList() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .json, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if url.pathExtension.lowercased() == "json" {
                guard let replacing = askReplaceOrMerge() else { return }
                report(try store.importJSON(from: url, replacing: replacing))
            } else {
                report(try store.importCSV(from: url))
            }
        } catch { NSAlert(error: error).runModal() }
    }

    /// Merge (the default), Replace or Cancel; nil when the user cancels.
    private func askReplaceOrMerge() -> Bool? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Replace your dictionary or merge?", comment: "Title of the alert shown when importing a JSON dictionary.")
        alert.informativeText = String(localized: "Merging keeps the words you already have and updates any that match. Replacing removes them first.", comment: "Explanation in the alert shown when importing a JSON dictionary.")
        alert.addButton(withTitle: String(localized: "Merge", comment: "Button that imports a dictionary without removing the existing words."))
        alert.addButton(withTitle: String(localized: "Replace", comment: "Button that replaces the whole dictionary with the imported one."))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Button that abandons the import."))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return false
        case .alertSecondButtonReturn: return true
        default: return nil
        }
    }

    private func report(_ applied: Int) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Imported \(applied) words.", comment: "Alert after importing a dictionary. The placeholder is how many words were imported.")
        alert.informativeText = String(localized: "Your dictionary now has \(store.entries.count) words.", comment: "Alert after importing a dictionary. The placeholder is how many words the dictionary holds now.")
        alert.addButton(withTitle: String(localized: "OK", comment: "Button that dismisses an alert."))
        alert.runModal()
    }

    private func exportList() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Murmur Dictionary.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.exportCSV(to: url) } catch { NSAlert(error: error).runModal() }
    }
}

// MARK: - About

private struct AboutSettings: View {
    @ObservedObject var updates: UpdateController
    @State private var showAcknowledgements = false
    private var version: String {
        let info = Bundle.main.infoDictionary
        return String(localized: "Version \(info?["CFBundleShortVersionString"] as? String ?? "0.1.0") (\(info?["CFBundleVersion"] as? String ?? "1"))", comment: "Version line in About: the marketing version, then the build number in brackets.")
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    AppIconView().frame(width: 96, height: 96)
                    Text("Murmur").font(.system(size: 22, weight: .bold))
                    Text(version).font(.callout).foregroundStyle(.secondary)
                    Text("Private dictation for your Mac. Nothing leaves your machine.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 2)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(get: { updates.automaticallyChecks }, set: { updates.automaticallyChecks = $0 }))
                LabeledContent("Last checked", value: updates.lastChecked.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? String(localized: "Never", comment: "Shown as the last update check time when Murmur has never checked."))
                Button("Check for Updates…") { updates.check() }.disabled(!updates.canCheck)
            }
            Section("Open source") {
                LabeledContent { LinkButton(title: "GitHub", url: "https://github.com/jrmd/murmur") } label: {
                    SettingLabel(title: "Source code", subtitle: "Murmur is free and open source under the MIT License.")
                }
            }
            Section("Built with") {
                LabeledContent { LinkButton(title: "Licence", url: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3") } label: {
                    SettingLabel(title: "Parakeet TDT 0.6B v3", subtitle: "Speech recognition by NVIDIA · CC BY 4.0")
                }
                LabeledContent { LinkButton(title: "Licence", url: "https://huggingface.co/moondream/parakeet-ultra") } label: {
                    SettingLabel(title: "Parakeet Ultra", subtitle: "Post-trained v3 by moondream · CC BY 4.0")
                }
                LabeledContent { LinkButton(title: "Licence", url: CleanupModel.murmurClean.licenceURL.absoluteString) } label: {
                    SettingLabel(title: "Murmur Clean 350M", subtitle: "Clean-up model by Bonus Objective, based on LFM2.5")
                }
                LabeledContent { LinkButton(title: "Licence", url: CleanupModel.lfm3.licenceURL.absoluteString) } label: {
                    SettingLabel(title: "LFM3", subtitle: "Clean-up model by Liquid AI")
                }
                LabeledContent {
                    Button { showAcknowledgements = true } label: { HStack(spacing: 3) { Text("View"); Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)).accessibilityHidden(true) } }
                        .buttonStyle(.plain).foregroundStyle(Color.murmurCoral)
                } label: { Text("Acknowledgements") }
            }
        }
        .formStyle(.grouped)
        .frame(height: 590)
        .sheet(isPresented: $showAcknowledgements) { AcknowledgementsView() }
    }
}

private struct LinkButton: View {
    let title: LocalizedStringKey
    let url: String
    var body: some View {
        Button { if let url = URL(string: url) { NSWorkspace.shared.open(url) } } label: {
            HStack(spacing: 3) { Text(title); Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)).accessibilityHidden(true) }
        }
        .buttonStyle(.plain).foregroundStyle(Color.murmurCoral)
        .accessibilityHint("Opens in your browser")
    }
}

private struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss
    /// Name, description, link. The names are product names and stay as they are.
    private let items: [(String, LocalizedStringKey, String)] = [
        ("FluidAudio", "Core ML speech recognition runtime for Apple silicon · Apache 2.0", "https://github.com/FluidInference/FluidAudio"),
        ("Parakeet TDT 0.6B", "NVIDIA speech recognition models · CC BY 4.0", "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3"),
        ("llama.cpp", "On-device inference for the clean-up model · MIT", "https://github.com/ggml-org/llama.cpp"),
        ("Sparkle", "Software updates · MIT", "https://github.com/sparkle-project/Sparkle"),
        ("Murmur Clean 350M", "Bonus Objective clean-up model, fine-tuned from Liquid AI LFM2.5-350M · LFM Open License v1.0", "https://huggingface.co/bonusobjective/murmur-clean-350m"),
        ("LFM3", "Liquid AI clean-up model · LFM Open License v1.0", "https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Acknowledgements").font(.title3.weight(.semibold))
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Text(item.0).font(.system(size: 13.5, weight: .semibold)); Spacer(); LinkButton(title: "Open", url: item.2) }
                    Text(item.1).font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 440)
    }
}
