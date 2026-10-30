import AppKit
import SwiftUI

/// Brand images are compiled into Assets.xcassets; menu-bar marks use template rendering.
@MainActor
enum BrandAssets {
    static func menuBarImage(recording: Bool) -> NSImage {
        let name = recording ? "MenuBarIcon-Recording" : "MenuBarIcon"
        let image = NSImage(named: NSImage.Name(name)) ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Murmur")!
        image.isTemplate = true
        return image
    }

    static func appIcon() -> NSImage? {
        NSImage(named: NSImage.Name("MurmurBrandMark"))
    }

    static func applyDockIcon() {
        if let icon = appIcon() { NSApp.applicationIconImage = icon }
    }
}

struct AppIconView: View {
    var body: some View {
        Image("MurmurBrandMark").resizable().interpolation(.high)
            .accessibilityLabel("Murmur app icon")
    }
}
