import SwiftUI

@main
struct WhispurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            MenuBarStatusIcon(phase: appState.pipeline.phase)
                .task {
                    appDelegate.connect(appState: appState)
                }
        }
        .menuBarExtraStyle(.window)

        Window("Orbit Dictation Settings", id: "settings") {
            SettingsView(appState: appState)
                .frame(minWidth: 860, minHeight: 620)
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentSize)

        Window("About Orbit Dictation", id: "about") {
            AboutView()
        }
        .defaultSize(width: 360, height: 360)
        .windowResizability(.contentSize)
    }
}

private struct MenuBarStatusIcon: View {
    let phase: PipelinePhase
    @AppStorage("settings.selectedTab") private var selectedTabRaw = SettingsTab.setup.rawValue
    @Environment(\.openWindow) private var openWindow

    @ViewBuilder
    var body: some View {
        Group {
            switch phase {
            case .recording:
                PulsingMenuBarIcon()
            case .normalizingAudio, .transcribing, .cleaningTranscript, .pasting:
                WorkingMenuBarIcon()
            case .idle:
                MenuBarGlyphIcon()
            case .requestingMicrophonePermission, .starting:
                MenuBarGlyphIcon(tint: .secondary)
                    .opacity(0.86)
            case .done:
                MenuBarGlyphIcon(tint: .green)
            case .error:
                MenuBarGlyphIcon(symbol: "mic.slash", tint: .orange)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .whispurOpenSettings)) { notification in
            if let tab = notification.object as? String {
                selectedTabRaw = tab
            }
            WindowUtilities.dismissMenuBarPopover()
            WindowUtilities.focusOrOpenWindow(id: .settings, using: openWindow)
        }
    }
}

private struct MenuBarGlyphIcon: View {
    var symbol: String = "mic"
    var tint: Color = .primary

    var body: some View {
        // SF Symbols template-render reliably in the menu bar at any size.
        // The system tints opaque pixels with the menu-bar foreground colour
        // (light/dark-mode aware) so we don't need a separate asset. Frame
        // sizing is the standard 16pt menu-bar glyph; SwiftUI scales the
        // symbol to fit and Retina handles the doubling.
        Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .frame(width: 16, height: 16)
            .foregroundStyle(tint)
            .accessibilityLabel("Orbit Dictation")
    }
}

private struct PulsingMenuBarIcon: View {
    @State private var isAnimating = false

    var body: some View {
        MenuBarGlyphIcon(symbol: "mic.fill", tint: .red)
            .scaleEffect(isAnimating ? 1.04 : 0.92)
            .opacity(isAnimating ? 1 : 0.72)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isAnimating)
            .onAppear {
                isAnimating = true
            }
    }
}

/// Subtle "working" pulse for transcribe/cleanup/paste phases. Spinning the
/// mic glyph itself reads as a graphical glitch — pulsing the opacity while
/// holding the same icon is closer to the "we're doing something with what
/// you said" intent.
private struct WorkingMenuBarIcon: View {
    @State private var isAnimating = false

    var body: some View {
        MenuBarGlyphIcon(tint: .blue)
            .opacity(isAnimating ? 1 : 0.55)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: isAnimating)
            .onAppear {
                isAnimating = true
            }
    }
}
