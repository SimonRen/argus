import Observation
import Sparkle

/// Sparkle's updater. It reads the feed in SUFeedURL (the latest GitHub release's appcast.xml) once a day, checks each
/// update against SUPublicEDKey, and asks before it installs anything.
@MainActor @Observable final class Updater {
    @ObservationIgnored private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var automaticallyChecks: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    init() {
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
