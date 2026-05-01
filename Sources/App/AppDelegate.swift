import AppKit
import Cocoa
import Foundation
import os

private let logger = Logger(subsystem: "team.yourorbit.OrbitDictation", category: "AppDelegate")

extension Notification.Name {
    static let whispurOpenSettings = Notification.Name("team.yourorbit.OrbitDictation.open-settings")
}

/// Handles application lifecycle events.
///
/// Owns `AppState` and the menu-bar controller, so both are alive before
/// any SwiftUI scene renders. Previously `AppState` was a SwiftUI
/// `@StateObject` on the App struct, with the AppDelegate adopting it
/// later via `connect(appState:)` triggered by a `.task` on the
/// `MenuBarExtra` content. That handoff worked but coupled the launch
/// sequence to SwiftUI's MenuBarExtra rendering — the same MenuBarExtra
/// whose status item kept disappearing. Now AppDelegate owns the state
/// directly; SwiftUI scenes read it via `appDelegate.appState`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Singleton handle for non-SwiftUI access. `@NSApplicationDelegateAdaptor`
    /// is supposed to make `NSApp.delegate as? AppDelegate` work, but on
    /// macOS Sequoia the cast returns nil at runtime — confirmed via Sir's
    /// diagnostic logs in v0.2.14: AppDelegate's methods run fine (proving
    /// it's wired in) but `NSApp.delegate as? AppDelegate` returns nil from
    /// callsites like `MenuBarView`. SwiftUI appears to wrap the user
    /// AppDelegate in a private adaptor class for `NSApp.delegate`, defeating
    /// the cast. This static handle bypasses the wrapper — we set it in
    /// `init()` (always runs on the main thread when SwiftUI instantiates
    /// the adaptor) and consumers read it directly.
    nonisolated(unsafe) static var shared: AppDelegate?

    /// Created eagerly so `appState` is available the moment SwiftUI
    /// starts evaluating its scene tree. AppDelegate is `@MainActor` and
    /// `@NSApplicationDelegateAdaptor` instantiates it on the main thread,
    /// which is the actor required by `AppState.init`.
    let appState = AppState()

    /// AppKit-managed menu bar status item. See `MenuBarController` for
    /// the rationale on why we bypass SwiftUI's `MenuBarExtra` here.
    let menuBar = MenuBarController()

    private var didFinishLaunching = false
    private var onboardingWindowController: OnboardingWindowController?
    private var settingsWC: SettingsWindowController?
    private var aboutWC: AboutWindowController?

    private static let lastLaunchedVersionKey = "lastLaunchedShortVersion"

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        logger.info("Comet launched from: \(Bundle.main.bundleURL.path, privacy: .public)")

        // Install the manual NSStatusItem and wire it to live AppState.
        // Has to come before any window-opening code runs so the menu-bar
        // icon is up before Settings auto-opens at launch.
        menuBar.attach(appState: appState)

        // First-launch obligations that previously hung off the
        // SwiftUI-side `connect(appState:)` handshake.
        appState.applyLaunchAtLoginPreference()

        // OnboardingWindow (and any future caller) posts `.whispurOpenSettings`
        // when it wants to drop the user into Settings on a particular tab.
        // Route those through the AppKit-owned `showSettings` opener.
        NotificationCenter.default.addObserver(
            forName: .whispurOpenSettings,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                let raw = (note.object as? String) ?? SettingsTab.setup.rawValue
                let tab = SettingsTab(rawValue: raw) ?? .setup
                self?.showSettings(tab: tab)
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
            showSettings()
        }
        return true
    }

    /// Handle our `comet://` URL scheme. Both Settings and About are now
    /// AppKit-managed (`SettingsWindowController` / `AboutWindowController`),
    /// so the URL is just a portable way to ask the app to surface one of
    /// them — no SwiftUI scene magic involved.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let host = urls.first(where: { $0.scheme == "comet" })?.host else { return }
        switch host {
        case "settings": showSettings()
        case "about": showAbout()
        default:
            logger.info("Ignoring unknown comet:// URL host: \(host, privacy: .public)")
        }
    }

    /// Open the Settings window on launch if onboarding is already done. The
    /// onboarding window covers first-install (it presents the setup checklist
    /// inline), so Settings only auto-opens for repeat launches — that's where
    /// the user has come back to the app expecting to see something. Skipped
    /// during onboarding to avoid stacking two windows on first run.
    private func openSettingsOnLaunchIfNeeded() {
        guard appState.onboardingCompleted else { return }
        guard onboardingWindowController == nil else { return }
        showSettings()
    }

    /// Open the About window. If a previous controller exists but its window
    /// isn't visible (closed by the user), drop it and create a fresh one —
    /// `NSHostingController`-backed windows on macOS Sequoia don't reliably
    /// re-show after `orderOut`/close, so reuse-and-reshow is unreliable.
    /// Recreating each time costs a small SwiftUI re-init and gives a
    /// guaranteed-visible window.
    func showAbout() {
        logger.info("showAbout: visible=\(self.aboutWC?.window?.isVisible ?? false ? "true" : "false", privacy: .public)")
        if aboutWC?.window?.isVisible == true {
            NSApp.activate(ignoringOtherApps: true)
            aboutWC?.window?.makeKeyAndOrderFront(nil)
            return
        }
        aboutWC = AboutWindowController()
        if let window = aboutWC?.window {
            DockIconController.shared.register(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        aboutWC?.showWindow(nil)
        aboutWC?.window?.makeKeyAndOrderFront(nil)
        aboutWC?.window?.orderFrontRegardless()
    }

    /// Open Settings, optionally focused on a specific tab. Same recreate-
    /// when-not-visible pattern as `showAbout` — fixes the "Settings won't
    /// reopen after first close" bug on macOS Sequoia, where re-showing a
    /// hidden NSHostingController-backed window silently no-ops.
    func showSettings(tab: SettingsTab = .setup) {
        logger.info("showSettings: tab=\(tab.rawValue, privacy: .public) visible=\(self.settingsWC?.window?.isVisible ?? false ? "true" : "false", privacy: .public)")

        // Persist the tab selection so the SettingsView's
        // `@AppStorage("settings.selectedTab")` picks it up on render.
        UserDefaults.standard.set(tab.rawValue, forKey: "settings.selectedTab")

        // Already-visible window: just bring it to the front. Cheap.
        if settingsWC?.window?.isVisible == true {
            NSApp.activate(ignoringOtherApps: true)
            settingsWC?.window?.makeKeyAndOrderFront(nil)
            return
        }

        // First call OR the previous window was closed by the user. Either
        // way, build a fresh controller. `isReleasedWhenClosed = false` on
        // the old window means it stays alive until we drop our reference
        // here; ARC frees both the old controller and its NSWindow.
        settingsWC = SettingsWindowController(appState: appState)
        if let window = settingsWC?.window {
            DockIconController.shared.register(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWC?.showWindow(nil)
        settingsWC?.window?.makeKeyAndOrderFront(nil)
        settingsWC?.window?.orderFrontRegardless()
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

    private func presentOnboardingIfNeeded() {
        guard didFinishLaunching,
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

    /// Open the menu-bar popover programmatically. Used by anything that
    /// needs to surface the popover content without a click on the icon.
    func openMenuBarPopover() {
        menuBar.openPopover()
    }

    /// Close the menu-bar popover. Used before opening a Settings/About
    /// window so the popover doesn't sit awkwardly over the new window.
    func closeMenuBarPopover() {
        menuBar.closePopover()
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
