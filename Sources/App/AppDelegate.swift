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
        logger.info("Comet launched from: \(Bundle.main.bundleURL.path, privacy: .public)")

        // Catch all `.whispurOpenSettings` posters (OnboardingWindow,
        // re-broadcast inside `postOpenSettings`, future call sites) and
        // route through the single AppKit-owned opener. Previously the
        // observer lived inside the SwiftUI `MenuBarExtra` label, but
        // observers in that label cause the status item to be discarded
        // on re-evaluation — which is what made the menu-bar icon vanish.
        NotificationCenter.default.addObserver(
            forName: .whispurOpenSettings,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                let tab = (note.object as? String) ?? SettingsTab.setup.rawValue
                self?.postOpenSettings(tab: tab)
            }
        }

        // App Translocation check first. macOS Gatekeeper silently copies an
        // unsigned + quarantined app to a randomised read-only path under
        // /private/var/folders/.../AppTranslocation/... on each launch. Any
        // Mic / Accessibility / Keychain grant the user makes is recorded
        // against that ephemeral path; the next launch produces a fresh
        // path so the grants don't apply. Detecting + blocking here is the
        // only way to keep the user from wasting time granting permissions
        // that won't persist.
        if showTranslocationAlertAndQuitIfNeeded() {
            return
        }

        presentOnboardingIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checkForPostUpdateGatekeeperHelp()
            self?.openSettingsOnLaunchIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Comet terminating")
    }

    /// Comet is a menu-bar app — the mic glyph in the status bar is the
    /// always-on surface. Without this override, AppKit treats closing
    /// Settings (or About, or the menu-bar popover) as "last window
    /// closed" and quits the process, taking the status-bar icon with
    /// it. Returning `false` keeps the process alive so the menu-bar
    /// icon stays put. Quit goes through the explicit Quit menu item.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// When the user clicks the .app (Finder, Dock, Spotlight, ⌘-tab) while
    /// the app is already running, open Settings. Without this, an LSUIElement
    /// app appears to do nothing on second-launch — there's no Dock icon to
    /// raise and the menu-bar popover only opens on click. macOS calls this
    /// hook with `hasVisibleWindows = false` on a fresh activation; we open
    /// Settings as the canonical "main" window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            postOpenSettings()
        }
        return true
    }

    /// Handle our `comet://` URL scheme. SwiftUI's `.handlesExternalEvents`
    /// on the Settings/About `Window` scenes is the primary handler — it
    /// creates the SwiftUI scene if one doesn't exist yet. We only step
    /// in here to focus an existing window if SwiftUI hasn't already done
    /// so. **Must not call `postOpenSettings`** — that would re-issue the
    /// URL open and loop. Activation alone is enough to surface whatever
    /// window SwiftUI created from the same URL.
    func application(_ application: NSApplication, open urls: [URL]) {
        let host = urls.first(where: { $0.scheme == "comet" })?.host
        guard let host else { return }
        let identifierFragment = host == "settings" ? "settings" : "about"
        NSApp.activate(ignoringOtherApps: true)
        if let existing = NSApp.windows.first(where: {
            ($0.identifier?.rawValue.contains(identifierFragment) ?? false) &&
            !String(describing: type(of: $0)).contains("MenuBarExtra") &&
            !String(describing: type(of: $0)).contains("StatusBar")
        }) {
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
        }
    }

    /// Open the Settings window on launch if onboarding is already done. The
    /// onboarding window covers first-install (it presents the setup checklist
    /// inline), so Settings only auto-opens for repeat launches — that's where
    /// the user has come back to the app expecting to see something. Skipped
    /// during onboarding to avoid stacking two windows on first run.
    private func openSettingsOnLaunchIfNeeded() {
        guard let appState, appState.onboardingCompleted else { return }
        guard onboardingWindowController == nil else { return }
        postOpenSettings()
    }

    private func postOpenSettings(tab: String = SettingsTab.setup.rawValue) {
        // Persist the tab selection so the SettingsView picks it up on its
        // next render. `selectedTab` is bound to `@AppStorage("settings.selectedTab")`
        // inside the Settings view hierarchy.
        UserDefaults.standard.set(tab, forKey: "settings.selectedTab")

        // Bring an existing Settings NSWindow to the front if SwiftUI has
        // already instantiated it. Cheaper than the URL-scheme round-trip
        // and avoids any chance of the URL handler queuing.
        if let existing = NSApp.windows.first(where: {
            ($0.identifier?.rawValue.contains("settings") ?? false) &&
            !String(describing: type(of: $0)).contains("MenuBarExtra") &&
            !String(describing: type(of: $0)).contains("StatusBar")
        }) {
            DockIconController.shared.register(existing)
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            // No re-broadcast — that would loop with our own observer.
            // Tab selection is already persisted to UserDefaults above;
            // the popover's `@AppStorage("settings.selectedTab")` and the
            // SettingsView's binding will pick it up.
            return
        }

        // No existing window — ask SwiftUI to instantiate the Settings scene
        // by opening its registered URL. The Settings `Window` scene is
        // wired to `comet://settings` via `.handlesExternalEvents`, so this
        // works from AppKit without needing the SwiftUI `openWindow`
        // environment action (which we can't get from AppDelegate).
        if let url = URL(string: "comet://settings") {
            NSWorkspace.shared.open(url)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Returns true if App Translocation is in effect and a blocking alert
    /// was shown. macOS uses paths like
    /// `/private/var/folders/<...>/AppTranslocation/<UUID>/d/<bundle>.app`
    /// for unsigned + quarantined apps; the path UUID rotates on each
    /// launch so any TCC grant becomes a one-shot.
    private func showTranslocationAlertAndQuitIfNeeded() -> Bool {
        let bundlePath = Bundle.main.bundleURL.path
        let isTranslocated =
            bundlePath.contains("/AppTranslocation/") ||
            bundlePath.hasPrefix("/private/var/folders/")

        guard isTranslocated else { return false }

        logger.error("App Translocation detected — running from \(bundlePath, privacy: .public)")

        let command = #"xattr -dr com.apple.quarantine "/Applications/Comet.app""#

        let alert = NSAlert()
        alert.messageText = "Comet can't keep permissions yet"
        alert.informativeText = """
            macOS is running this build from a translocated location because the Gatekeeper quarantine flag is still attached. Any Microphone or Accessibility permission you grant in this state would be associated with a path that changes on every launch — so the grants won't persist.

            Fix it once: quit Comet, run this in Terminal, then relaunch from /Applications.

            \(command)

            Click 'Copy & open Terminal' to copy the command and launch Terminal in one go.
            """
        alert.alertStyle = .critical
        if let icon = NSImage(named: "AppIcon") { alert.icon = icon }
        alert.addButton(withTitle: "Copy & open Terminal")
        alert.addButton(withTitle: "Copy command")
        alert.addButton(withTitle: "Quit")

        if let window = alert.window as? NSPanel {
            window.level = .floating
        }
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(command, forType: .string)

        if response == .alertFirstButtonReturn {
            let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open(terminalURL)
        }

        // Always quit after the dialog — there is no point continuing the
        // current process; the user needs to relaunch from a stable path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }

        return true
    }

    func connect(appState: AppState) {
        guard self.appState !== appState else { return }
        self.appState = appState
        presentOnboardingIfNeeded()
        // Reconcile the OS login-item registration with the user's
        // `launchAtLoginEnabled` preference (default ON). First-install
        // users will see a System Settings approval prompt the first
        // time this fires. Lives here rather than in
        // applicationDidFinishLaunching because appState isn't connected
        // until MenuBarExtra's .task runs, which is after launch.
        appState.applyLaunchAtLoginPreference()
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
        let command = #"xattr -dr com.apple.quarantine "/Applications/Comet.app""#

        let alert = NSAlert()
        alert.messageText = "Comet updated to \(current)"
        alert.informativeText = """
            macOS may quarantine the new build the first time it relaunches and refuse to open it (you'll see "Comet can't be opened because Apple cannot check it for malicious software" or similar).

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
