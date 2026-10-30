import AppKit
import MurmurCore
import SwiftUI

/// Menu-bar popover: status first, errors inline as a banner, plain rows with right-aligned shortcuts.
struct MenuContent: View {
    @ObservedObject var controller: AppController
    @ObservedObject var updates: UpdateController
    @Environment(\.openSettings) private var openSettings
    @State private var showDetails = false

    private enum Status { case ready, setup, listening, working }
    private var status: Status {
        switch controller.statusText {
        case "Listening": return .listening
        case "Transcribing", "Tidying": return .working
        default: return controller.permissionsReady && controller.modelsReady ? .ready : .setup
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if controller.isPreparing { preparingBanner.padding(.top, 10) }
            else if let banner { bannerView(banner).padding(.top, 10) }
            Rule()
            MenuToggleRow(symbol: "sparkles", title: "Clean-up", isOn: $controller.cleanupEnabled)
                .disabled(!controller.modelsReady).opacity(controller.modelsReady ? 1 : 0.45)
            MenuRow(symbol: "doc.on.clipboard", title: "Paste Last Dictation", subtitle: controller.lastInserted.map { "“\($0.replacingOccurrences(of: "\n", with: " "))”" },
                    shortcut: "⌥⇧V", enabled: controller.lastInserted != nil) { controller.pasteLastDictation() }
            Rule()
            MenuRow(symbol: "gearshape", title: "Settings…", shortcut: "⌘,") { NSApp.activate(ignoringOtherApps: true); openSettings() }
                .keyboardShortcut(",")
            MenuRow(symbol: "checkmark.shield", title: "Setup & Permissions…") { controller.showOnboarding = true }
            MenuRow(symbol: "arrow.triangle.2.circlepath", title: "Check for Updates…", enabled: updates.canCheck) { updates.check() }
            Rule()
            MenuRow(symbol: "power", title: "Quit Murmur", shortcut: "⌘Q") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(10)
        .frame(width: 340)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconView().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Murmur").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    StatusBadge(status: badge)
                }
                HStack(spacing: 5) {
                    Text(controller.mode == "Toggle" ? "Press" : "Hold").foregroundStyle(.secondary)
                    ForEach(Array(ShortcutLabel.parts(code: controller.hotkeyCode, modifiers: controller.hotkeyModifiers).enumerated()), id: \.offset) { _, part in
                        Text(part.label).font(.system(size: 11.5, weight: .semibold)).padding(.horizontal, 5).frame(minWidth: 20, minHeight: 17)
                            .background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Text("to dictate").foregroundStyle(.secondary)
                }
                .font(.system(size: 12.5))
                HStack(spacing: 6) {
                    Circle().fill(controller.modelsReady ? Color.murmurGreen : Color.secondary.opacity(0.6)).frame(width: 6, height: 6)
                    Text(controller.modelsReady ? "Parakeet v3 · \(controller.cleanupModel.shortName) ready · on-device" : "Local models not downloaded")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 4).padding(.top, 2)
    }

    private var badge: StatusBadge.Kind {
        switch status {
        case .ready: .ready
        case .setup: .setup
        case .listening: .listening
        case .working: .working
        }
    }

    // MARK: Banners

    private struct Banner { let title: String; let message: String; let detail: String?; let severe: Bool }
    private var banner: Banner? {
        if let failure = controller.cleanupNotice {
            return Banner(title: "Clean-up skipped", message: "Clean-up failed, so Murmur pasted the raw transcript.", detail: failure, severe: false)
        }
        if let message = controller.errorMessage, controller.statusText == "Error" {
            return Banner(title: "Dictation failed", message: message, detail: nil, severe: true)
        }
        return nil
    }

    private func bannerView(_ banner: Banner) -> some View {
        let tint: Color = banner.severe ? .red : .murmurAmber
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(tint)
                Text(banner.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if banner.detail != nil {
                    Button { withAnimation(.easeOut(duration: 0.15)) { showDetails.toggle() } } label: {
                        HStack(spacing: 2) { Text("Details"); Image(systemName: "chevron.right").rotationEffect(.degrees(showDetails ? 90 : 0)).font(.system(size: 9, weight: .semibold)) }
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            Text(banner.message).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if showDetails, let detail = banner.detail {
                Text(detail).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.tertiary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1))
    }

    private var preparingBanner: some View {
        let fraction = controller.prepareFraction
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.down.circle").font(.system(size: 14, weight: .semibold))
                Text("Preparing Local Models").font(.system(size: 13.5, weight: .semibold))
                Spacer()
                if let fraction { Text("\(Int(fraction * 100))%").font(.system(size: 13, weight: .semibold).monospacedDigit()).contentTransition(.numericText()) }
            }
            ZStack(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(.white.opacity(0.28))
                    Capsule().fill(.white).frame(width: max(6, proxy.size.width * CGFloat(fraction ?? 0.06)))
                }
            }.frame(height: 4)
            Text(controller.prepareDescription.isEmpty ? "Starting…" : controller.prepareDescription)
                .font(.system(size: 12)).opacity(0.9)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(OB.primaryGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Pieces

private struct Rule: View {
    var body: some View { Divider().opacity(0.5).padding(.vertical, 6).padding(.horizontal, 4) }
}

private struct StatusBadge: View {
    enum Kind { case ready, setup, listening, working }
    let status: Kind
    private var label: String { [Kind.ready: "Ready", .setup: "Setup needed", .listening: "Listening", .working: "Working…"][status]! }
    private var tint: Color { [Kind.ready: Color.murmurGreen, .setup: .murmurAmber, .listening: .murmurCoral, .working: .murmurCoral][status]! }
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(label).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9).frame(height: 22)
        .background(tint.opacity(0.15), in: .capsule)
    }
}

private struct MenuRow: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var shortcut: String?
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18).padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13.5))
                    if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }
                }
                Spacer(minLength: 8)
                if let shortcut { Text(shortcut).font(.system(size: 12.5)).foregroundStyle(.tertiary).padding(.top, 1) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering && enabled ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}

private struct MenuToggleRow: View {
    let symbol: String
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
            Text(title).font(.system(size: 13.5))
            Spacer()
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().tint(.murmurCoral).controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }
}
