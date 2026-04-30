import AppKit
import Foundation
import Sparkle

@MainActor
final class SparkleUpdater: ObservableObject {
    private let controller: SPUStandardUpdaterController

    /// Mirror of `controller.updater.automaticallyChecksForUpdates`. Sparkle
    /// persists the preference under `SUEnableAutomaticChecks` itself; the
    /// `@Published` shadow is here so SwiftUI bindings can observe + drive
    /// changes without poking Sparkle directly from the view.
    @Published var automaticallyChecksForUpdates: Bool

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    func checkForUpdatesInBackground() {
        controller.updater.checkForUpdatesInBackground()
    }

    /// Toggle Sparkle's automatic background checking. When off, Sparkle
    /// won't poll for new versions and — critically for unsigned-app TCC
    /// stability — won't have a downloaded update sitting in queue ready to
    /// install on the next quit. Use during testing windows when you don't
    /// want the binary hash to drift.
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = enabled
    }
}

enum AppVersion {
    static var description: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "100"
        return "v\(shortVersion) (\(build))"
    }
}
