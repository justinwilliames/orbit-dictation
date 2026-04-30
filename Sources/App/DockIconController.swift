import AppKit
import Foundation

@MainActor
final class DockIconController {
    static let shared = DockIconController()

    private struct TrackedWindow {
        weak var window: NSWindow?
        var observer: NSObjectProtocol
    }

    private var tracked: [ObjectIdentifier: TrackedWindow] = [:]

    private init() {}

    func register(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        if tracked[id] == nil {
            let observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] notification in
                guard let closed = notification.object as? NSWindow else { return }
                let closedID = ObjectIdentifier(closed)
                Task { @MainActor [weak self] in
                    self?.handleClose(id: closedID)
                }
            }
            tracked[id] = TrackedWindow(window: window, observer: observer)
        }
        updateActivationPolicy()
    }

    private func handleClose(id: ObjectIdentifier) {
        if let entry = tracked.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(entry.observer)
        }
        updateActivationPolicy()
    }

    private func updateActivationPolicy() {
        // Comet stays menu-bar-only: no Dock icon ever, even while Settings /
        // About / Onboarding windows are visible. LSUIElement=true in
        // Info.plist keeps us off the Dock at launch; this guard pulls us
        // back to .accessory if anything else flips us to .regular.
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }

        // Drop stale weak-window entries so the tracked map doesn't leak.
        var staleKeys: [ObjectIdentifier] = []
        for (key, entry) in tracked where entry.window == nil {
            staleKeys.append(key)
        }
        for key in staleKeys {
            if let entry = tracked.removeValue(forKey: key) {
                NotificationCenter.default.removeObserver(entry.observer)
            }
        }
    }
}
