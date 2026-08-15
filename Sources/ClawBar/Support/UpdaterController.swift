import AppKit
import Combine
import Sparkle
import UserNotifications

/// Sparkle's user driver delegate.
///
/// ClawBar is `LSUIElement`, so it cannot reliably raise its own windows — Sparkle's
/// update prompts would open behind whatever the user is looking at, exactly as the
/// onboarding window did before it was fixed. Activating the app first is the whole job
/// of this object.
private final class UpdaterUIDelegate: NSObject, SPUStandardUserDriverDelegate {
    /// No dock icon means no bounce, so Sparkle should not assume a scheduled reminder
    /// was actually seen.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillShowModalAlert() {
        NSApp.activate()
    }
}

@MainActor
final class UpdaterController: ObservableObject {
    private let uiDelegate: UpdaterUIDelegate
    private let controller: SPUStandardUpdaterController
    private var cancellables = Set<AnyCancellable>()

    @Published private(set) var canCheck = false
    @Published var automaticallyChecks: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    init() {
        let delegate = UpdaterUIDelegate()
        uiDelegate = delegate
        // Started manually below so the published properties are wired up first.
        controller = SPUStandardUpdaterController(startingUpdater: false,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: delegate)
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheck = value }
            .store(in: &cancellables)

        controller.startUpdater()
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    var version: String { bundleVersionString() }

    func checkForUpdates() {
        NSApp.activate()
        controller.updater.checkForUpdates()
    }

    /// Settings already has this object to hand; routing the query through it avoids
    /// threading a second dependency into the view purely to read one status.
    func notificationAuthorization() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
