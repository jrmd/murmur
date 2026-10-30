import AppKit
import SwiftUI

// MARK: - Tokens (murmur-onboarding/DESIGN-SPEC.md)

extension Color {
    static let murmurCoral = Color(red: 1.0, green: 0.541, blue: 0.420)       // #FF8A6B
    static let murmurCoralDeep = Color(red: 0.949, green: 0.404, blue: 0.290)  // #F2674A
    static let murmurGreen = Color(red: 0.204, green: 0.780, blue: 0.482)      // #34C77B
    static let murmurAmber = Color(red: 1.0, green: 0.710, blue: 0.278)        // #FFB547

    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }
}

enum OB {
    static let text = Color(light: Color(red: 0.118, green: 0.098, blue: 0.090), dark: Color(red: 0.965, green: 0.945, blue: 0.937))
    static let secondary = text.opacity(0.66)
    static let tertiary = text.opacity(0.42)
    static let track = Color(light: Color(red: 0.235, green: 0.118, blue: 0.078).opacity(0.09), dark: .white.opacity(0.09))
    static let cardFill = Color(light: .white.opacity(0.35), dark: .white.opacity(0.04))
    static let cardStroke = Color(light: Color(red: 0.235, green: 0.118, blue: 0.078).opacity(0.08), dark: .white.opacity(0.10))
    static let greenText = Color(light: Color(red: 0.118, green: 0.620, blue: 0.353), dark: Color(red: 0.373, green: 0.886, blue: 0.604))
    static let amberText = Color(light: Color(red: 0.722, green: 0.431, blue: 0), dark: Color(red: 1.0, green: 0.773, blue: 0.431))
    static let coralText = Color(light: Color(red: 0.88, green: 0.36, blue: 0.25), dark: .murmurCoral)

    static let primaryGradient = LinearGradient(
        colors: [Color(red: 1.0, green: 0.596, blue: 0.471), Color(red: 0.961, green: 0.439, blue: 0.310), Color(red: 0.933, green: 0.380, blue: 0.259)],
        startPoint: .top, endPoint: .bottom)
    static let progressGradient = LinearGradient(colors: [.murmurCoral, .murmurCoralDeep], startPoint: .leading, endPoint: .trailing)
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 36)
            .background {
                Capsule().fill(OB.primaryGradient)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.75).mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)))
            }
            .shadow(color: .murmurCoralDeep.opacity(enabled ? 0.42 : 0), radius: 9, y: 4)
            .opacity(enabled ? 1 : 0.38)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GlassCapsuleStyle: ButtonStyle {
    var small = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? 12.5 : 14, weight: .semibold))
            .foregroundStyle(OB.text)
            .padding(.horizontal, small ? 14 : 20)
            .frame(height: small ? 28 : 36)
            .glassEffect(.regular.interactive(), in: .capsule)
            .background(OB.text.opacity(0.07), in: .capsule)
            .overlay(Capsule().strokeBorder(OB.cardStroke, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct PrimaryButton: View {
    let title: String
    var symbol: String?
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)) }
                Text(title)
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!enabled)
    }
}

// MARK: - Status pill

enum PillKind {
    case needed, waiting, granted, downloading, notDownloaded, ready, denied

    var label: String {
        switch self {
        case .needed: "Needed"
        case .waiting: "Waiting for System Settings"
        case .granted: "Granted"
        case .downloading: "Downloading"
        case .notDownloaded: "Not downloaded"
        case .ready: "Ready"
        case .denied: "Denied"
        }
    }
}

struct Spinner: View {
    var color: Color
    @State private var spinning = false
    var body: some View {
        Circle().trim(from: 0, to: 0.78)
            .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spinning = true } }
    }
}

struct StatusPill: View {
    let kind: PillKind
    private var tint: Color {
        switch kind {
        case .granted, .ready: .murmurGreen
        case .waiting: .murmurAmber
        case .downloading: .murmurCoral
        case .denied: .red
        case .needed, .notDownloaded: OB.text
        }
    }
    private var textColor: Color {
        switch kind {
        case .granted, .ready: OB.greenText
        case .waiting: OB.amberText
        case .downloading: OB.coralText
        case .denied: .red
        case .needed, .notDownloaded: OB.secondary
        }
    }
    var body: some View {
        HStack(spacing: 6) {
            switch kind {
            case .granted, .ready: Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
            case .waiting, .downloading: Spinner(color: textColor)
            case .denied: Image(systemName: "xmark.circle.fill").font(.system(size: 12))
            case .needed, .notDownloaded: Circle().strokeBorder(textColor, style: StrokeStyle(lineWidth: 1.2, dash: [2, 2])).frame(width: 11, height: 11)
            }
            Text(kind.label).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(tint.opacity(tint == OB.text ? 0.06 : 0.14), in: .capsule)
        .overlay(Capsule().strokeBorder(tint.opacity(tint == OB.text ? 0.12 : 0.28), lineWidth: 1))
        .animation(.easeOut(duration: 0.2), value: kind.label)
    }
}

// MARK: - Layout pieces

struct StepHeader: View {
    let symbol: String
    var customIcon: AnyView?
    let eyebrow: String
    let title: String
    var pill: PillKind?

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [.murmurCoral.opacity(0.30), .murmurCoralDeep.opacity(0.14)], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.murmurCoral.opacity(0.35), lineWidth: 1)
                if let customIcon { customIcon } else {
                    Image(systemName: symbol).font(.system(size: 24, weight: .regular)).foregroundStyle(Color.murmurCoral)
                }
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow.uppercased()).font(.system(size: 11.5, weight: .semibold)).tracking(0.6).foregroundStyle(OB.tertiary)
                Text(title).font(.system(size: 28, weight: .bold)).tracking(-0.6).foregroundStyle(OB.text)
            }
            Spacer(minLength: 12)
            if let pill { StatusPill(kind: pill) }
        }
    }
}

struct Lead: View {
    let text: Text
    init(_ text: Text) { self.text = text }
    init(_ string: String) { self.text = Text(string) }
    var body: some View {
        text.font(.system(size: 15)).foregroundStyle(OB.secondary).lineSpacing(3.5)
            .frame(maxWidth: 600, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    func obCard(radius: CGFloat = 18, tint: Color? = nil) -> some View {
        glassEffect(tint.map { .regular.tint($0) } ?? .regular, in: .rect(cornerRadius: radius))
            .background(OB.cardFill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(OB.cardStroke, lineWidth: 1))
    }
}

struct IconChip: View {
    let symbol: String
    var size: CGFloat = 34
    var radius: CGFloat = 10
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(Color.murmurCoral)
            .frame(width: size, height: size)
            .background(Color.murmurCoral.opacity(0.16), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

enum StepMark { case done, current, future }

struct NumberedStep: View {
    let number: Int
    let mark: StepMark
    let text: Text
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                switch mark {
                case .done:
                    Circle().fill(Color.murmurGreen)
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                case .current:
                    Circle().fill(Color.murmurCoral).overlay(Circle().stroke(Color.murmurCoral.opacity(0.28), lineWidth: 3))
                    Text("\(number)").font(.system(size: 11.5, weight: .bold)).foregroundStyle(.white)
                case .future:
                    Circle().fill(OB.cardFill).overlay(Circle().strokeBorder(OB.cardStroke, lineWidth: 1))
                    Text("\(number)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(OB.secondary)
                }
            }
            .frame(width: 22, height: 22)
            text.font(.system(size: 14.5)).foregroundStyle(mark == .future ? OB.secondary : OB.text)
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true).padding(.top, 1.5)
        }
    }
}

struct Stepper: View {
    let current: Int
    let count: Int
    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? AnyShapeStyle(OB.primaryGradient) : index < current ? AnyShapeStyle(Color.murmurCoral.opacity(0.62)) : AnyShapeStyle(OB.track))
                    .frame(width: index == current ? 24 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: current)
    }
}

struct Keycap: View {
    let label: String
    var symbol: String?
    var active = false
    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 14, weight: .regular)).foregroundStyle(OB.secondary) }
            Text(label).font(.system(size: 20, weight: .semibold)).foregroundStyle(OB.text)
        }
        .padding(.horizontal, 16)
        .frame(minWidth: 58, minHeight: 46)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(active ? Color.murmurCoral : .clear, lineWidth: 1.5))
        .shadow(color: active ? Color.murmurCoral.opacity(0.35) : .clear, radius: 8)
    }
}

/// Stylised mini System Settings window used on the permission screens.
struct SettingsIllustration: View {
    let pane: String
    var caption = "Allow the apps below to control your computer."
    let murmurOn: Bool
    var highlight = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(OB.text.opacity(0.18)).frame(width: 7, height: 7) }
                Text("Privacy & Security").font(.system(size: 12)).foregroundStyle(OB.secondary).lineLimit(1).fixedSize().padding(.leading, 2)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(OB.tertiary)
                Text(pane).font(.system(size: 12, weight: .semibold)).foregroundStyle(OB.text).lineLimit(1).fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).frame(height: 36)
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 8) {
                Text(caption).font(.system(size: 11.5)).foregroundStyle(OB.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    row(name: "Terminal", on: false, icon: AnyView(RoundedRectangle(cornerRadius: 5).fill(OB.text.opacity(0.85).opacity(0.18))))
                    row(name: "Murmur", on: murmurOn, bold: true, tag: !murmurOn && highlight, focused: highlight, icon: AnyView(Image("MurmurBrandMark").resizable()))
                    row(name: "Script Editor", on: true, icon: AnyView(RoundedRectangle(cornerRadius: 5).fill(OB.text.opacity(0.22))))
                }
                .background(OB.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(OB.cardStroke, lineWidth: 1))
            }
            .padding(12)
        }
        .frame(width: 296)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func row(name: String, on: Bool, bold: Bool = false, tag: Bool = false, focused: Bool = false, icon: AnyView) -> some View {
        HStack(spacing: 10) {
            icon.frame(width: 20, height: 20)
            Text(name).font(.system(size: 13, weight: bold ? .semibold : .regular)).foregroundStyle(bold ? OB.text : OB.secondary)
            Spacer()
            if tag {
                Text("Turn on").font(.system(size: 11.5, weight: .medium)).foregroundStyle(OB.coralText)
                    .padding(.horizontal, 8).frame(height: 20).background(Color.murmurCoral.opacity(0.16), in: .capsule)
            }
            MiniToggle(on: on)
        }
        .padding(.horizontal, 10).frame(height: 35)
        .background {
            if focused { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.murmurCoral.opacity(0.10)) }
        }
        .overlay {
            if focused { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.murmurCoral.opacity(0.7), lineWidth: 1.2) }
        }
    }
}

struct MiniToggle: View {
    let on: Bool
    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? Color.murmurGreen : OB.text.opacity(0.16)).frame(width: 36, height: 21)
            Circle().fill(.white).frame(width: 17, height: 17).padding(2).shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: on)
    }
}

/// Dark glass listening capsule; the real dictation HUD can reuse this.
struct ListeningHUD: View {
    let level: Float
    let label: String
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.murmurCoral).frame(width: 9, height: 9).shadow(color: .murmurCoral.opacity(0.8), radius: 4)
            LevelBars(level: level)
            Text(label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 16).frame(height: 40)
        .background(.black.opacity(0.72), in: .capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }
}

struct LevelBars: View {
    let level: Float
    var count = 11
    var color: Color = .murmurCoral
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<count, id: \.self) { index in
                let shape = CGFloat(0.35 + 0.65 * abs(sin(Double(index) * 0.9 + 0.6)))
                Capsule().fill(color)
                    .frame(width: 2.5, height: max(3, 20 * CGFloat(min(1, level * 1.4)) * shape))
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
