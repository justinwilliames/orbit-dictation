import AppKit
import Cocoa
import Foundation
import os

private let logger = Logger(subsystem: "team.yourorbit.OrbitDictation", category: "AppDelegate")

extension Notification.Name {
    static let whispurOpenSettings = Notification.Name("team.yourorbit.OrbitDictation.open-settings")
}

/// Handles application lifecycle events.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var appState: AppState?
    private var didFinishLaunching = false
    private var onboardingWindowController: OnboardingWindowController?

    private static let lastLaunchedVersionKey = "lastLaunchedShortVersion"

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        logger.info("Orbit Dictation launched")
        presentOnboardingIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checkForPostUpdateGatekeeperHelp()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Orbit Dictation terminating")
    }

    func connect(appState: AppState) {
        guard self.appState !== appState else { return }
        self.appState = appState
        presentOnboardingIfNeeded()
    }

    private func presentOnboardingIfNeeded() {
        guard didFinishLaunching,
              let appState,
              !appState.onboardingCompleted,
              onboardingWindowController == nil else {
            return
        }

        let controller = OnboardingWindowController(appState: appState) { [weak self] in
            self?.onboardingWindowController = nil
        }
        onboardingWindowController = controller
        controller.present()
    }

    // MARK: - Post-update Gatekeeper help

    /// macOS re-quarantines an unsigned .app every time Sparkle replaces it.
    /// Until the app is signed and notarised, the user has to run the xattr
    /// command after every auto-update or Gatekeeper refuses to launch the
    /// new build. This helper fires when the app version changes between
    /// launches (the Sparkle-update signal) and surfaces a one-click
    /// "Copy & open Terminal" dialog. Skipped on first install (no previous
    /// version on record) and on relaunches of the same version.
    private func checkForPostUpdateGatekeeperHelp() {
        let currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        guard !currentVersion.isEmpty else { return }
        let defaults = UserDefaults.standard
        let last = defaults.string(forKey: AppDelegate.lastLaunchedVersionKey)
        defaults.set(currentVersion, forKey: AppDelegate.lastLaunchedVersionKey)

        guard let last, last != currentVersion else { return }

        showPostUpdateGatekeeperHelpDialog(previous: last, current: currentVersion)
    }

    private func showPostUpdateGatekeeperHelpDialog(previous: String, current: String) {
        let command = #"xattr -dr com.apple.quarantine "/Applications/Orbit Dictation.app""#

        let alert = NSAlert()
        alert.messageText = "Orbit Dictation updated to \(current)"
        alert.informativeText = """
            macOS may quarantine the new build the first time it relaunches and refuse to open it (you'll see "Orbit Dictation can't be opened because Apple cannot check it for malicious software" or similar).

            Run this command in Terminal once to allow it through:

            \(command)

            Click 'Copy & open Terminal' to copy the command and launch Terminal in one go — paste with ⌘V and hit Return.
            """
        alert.alertStyle = .informational
        if let icon = NSImage(named: "AppIcon") { alert.icon = icon }
        alert.addButton(withTitle: "Copy & open Terminal")
        alert.addButton(withTitle: "Copy command")
        alert.addButton(withTitle: "Dismiss")

        if let window = alert.window as? NSPanel {
            window.level = .floating
        }
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(command, forType: .string)
            let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open(terminalURL)
        case .alertSecondButtonReturn:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(command, forType: .string)
        default:
            break
        }
    }
}
