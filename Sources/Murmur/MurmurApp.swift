import AppKit
import SwiftUI
import MurmurCore

@main
struct MurmurApp: App {
    @StateObject private var controller = AppController()
    @StateObject private var updates = UpdateController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller, updates: updates)
        } label: {
            HStack(spacing: 3) {
                Image(nsImage: BrandAssets.menuBarImage(recording: controller.statusText == "Listening"))
                #if DEBUG
                Text("dev")
                #endif
            }
            .accessibilityLabel(controller.menuTitle)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(controller: controller, updates: updates)
        }
    }
}
