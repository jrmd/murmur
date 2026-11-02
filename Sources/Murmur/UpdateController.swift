import Combine
import Foundation
import Sparkle

final class UpdateController: ObservableObject {
    #if DEBUG
    /// The dev build never checks for updates, so a published release can't replace it.
    private let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    #else
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif
    private var observations = Set<AnyCancellable>()
    @Published private(set) var canCheck = false
    @Published private(set) var lastChecked: Date?
    @Published var automaticallyChecks = false {
        didSet {
            if controller.updater.automaticallyChecksForUpdates != automaticallyChecks {
                controller.updater.automaticallyChecksForUpdates = automaticallyChecks
            }
        }
    }

    init() {
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheck)
        updater.publisher(for: \.lastUpdateCheckDate).receive(on: RunLoop.main).assign(to: &$lastChecked)
        updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main).assign(to: &$automaticallyChecks)
    }

    func check() { controller.checkForUpdates(nil) }
}
