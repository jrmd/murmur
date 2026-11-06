import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowPresenter()
    private weak var controller: AppController?
    private var window: NSWindow?

    func show(controller: AppController) {
        self.controller = controller
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = String(localized: "Welcome to Murmur", comment: "Title of the setup window, also used as its accessibility title.")
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior.insert(.moveToActiveSpace)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-obLight") { window.appearance = NSAppearance(named: .aqua) }
            #endif

            let hosting = NSHostingView(rootView: OnboardingView(controller: controller) { self.controller?.showOnboarding = false })
            hosting.sizingOptions = []
            hosting.frame = NSRect(x: 0, y: 0, width: 760, height: 560)
            hosting.autoresizingMask = [.width, .height]

            // Real Liquid Glass behind the content; the warm tint keeps it from reading as cold grey.
            let glass = NSGlassEffectView(frame: hosting.frame)
            glass.cornerRadius = 0
            glass.tintColor = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(red: 30 / 255, green: 24 / 255, blue: 26 / 255, alpha: 0.38)
                    : NSColor(red: 253 / 255, green: 250 / 255, blue: 248 / 255, alpha: 0.30)
            }
            glass.contentView = hosting
            window.contentView = glass
            window.setContentSize(NSSize(width: 760, height: 560))
            window.center()
            window.delegate = self
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window?.orderFrontRegardless()
    }

    func close() {
        guard window?.isVisible == true else { return }
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    func windowWillClose(_ notification: Notification) {
        guard controller?.showOnboarding == true else { return }
        controller?.showOnboarding = false
        NSApp.setActivationPolicy(.accessory)
    }
}
