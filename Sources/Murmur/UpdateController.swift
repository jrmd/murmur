import Combine
import Foundation
import Sparkle

final class UpdateController: ObservableObject {
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
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
