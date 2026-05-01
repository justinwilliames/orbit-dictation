import SwiftUI

@main
struct WhispurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
                .task {
                    // The connect call lived on the label until we hit a
                    // SwiftUI bug where reactive dependencies in the label
                    // (`.task`, `.onReceive`, `@AppStorage`) caused the
                    // status item to be torn down and re-created shortly
                    // after launch — leaving an orphaned NSStatusItem
                    // and an invisible menu-bar slot. Side-effects belong
                    // in the popover content, never in the label.
                    appDelegate.connect(appState: appState)
                }
        } label: {
            MenuBarStatusIcon(phase: appState.pipeline.phase)
        }
        .menuBarExtraStyle(.window)

        Window("Comet Settings", id: "settings") {
            SettingsView(appState: appState)
                .frame(minWidth: 860, minHeight: 620)
                // Routes `comet://settings` URLs to this scene. AppDelegate
                // uses `NSWorkspace.shared.open` to trigger this on launch
                // and on second-activation, since AppKit can't directly
                // call SwiftUI's `openWindow` environment action without
                // a SwiftUI view in scope. URL scheme is registered in
                // Info.plist via CFBundleURLTypes.
                .handlesExternalEvents(preferring: ["settings"], allowing: ["*"])
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: ["settings"])

        Window("About Comet", id: "about") {
            AboutView()
                .handlesExternalEvents(preferring: ["about"], allowing: ["*"])
        }
        .defaultSize(width: 360, height: 360)
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: ["about"])
    }
}

/// Status-bar label for the `MenuBarExtra`.
///
/// **Stability rules — do not violate:**
/// 1. Always render exactly the same concrete view type (`MenuBarGlyphIcon`).
///    SwiftUI's `MenuBarExtra` will tear down and discard the underlying
///    `NSStatusItem` if the label switches between distinct view types
///    (e.g. `PulsingMenuBarIcon` vs `MenuBarGlyphIcon`) on phase change.
///    Symptom: icon vanishes shortly after launch even though the process
///    is still running.
/// 2. No `.task`, `.onReceive`, `@AppStorage`, `@Environment(\.openWindow)`,
///    or any other reactive dependency that causes label re-evaluation
///    beyond the single `phase` input. Those belong in the popover content
///    or in `AppDelegate`.
/// 3. Animations live *inside* `MenuBarGlyphIcon` and are driven by the
///    `phase` value passed in — never by swapping wrapper views.
private struct MenuBarStatusIcon: View {
    let phase: PipelinePhase

    var body: some View {
        MenuBarGlyphIcon(phase: phase)
    }
}

/// Single concrete view that renders every phase of the menu-bar icon.
///
/// Kept as one view type so SwiftUI's `MenuBarExtra` doesn't tear down the
/// underlying `NSStatusItem` when phase changes. All visual differences
/// (symbol, tint, animation) are driven by the `phase` property; the view
/// hierarchy itself never swaps.
private struct MenuBarGlyphIcon: View {
    let phase: PipelinePhase

    @State private var isAnimating = false

    private var symbol: String? {
        switch phase {
        case .recording: return "mic.fill"
        case .error: return "mic.slash"
        default: return nil
        }
    }

    private var tint: Color {
        switch phase {
        case .recording: return .red
        case .normalizingAudio, .transcribing, .cleaningTranscript, .pasting: return .blue
        case .requestingMicrophonePermission, .starting: return .secondary
        case .done: return .green
        case .error: return .orange
        case .idle: return .primary
        }
    }

    private var iconOpacity: Double {
        switch phase {
        case .recording:
            return isAnimating ? 1.0 : 0.72
        case .normalizingAudio, .transcribing, .cleaningTranscript, .pasting:
            return isAnimating ? 1.0 : 0.55
        case .requestingMicrophonePermission, .starting:
            return 0.86
        default:
            return 1.0
        }
    }

    private var iconScale: CGFloat {
        switch phase {
        case .recording: return isAnimating ? 1.04 : 0.92
        default: return 1.0
        }
    }

    private var animation: Animation? {
        switch phase {
        case .recording:
            return .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
        case .normalizingAudio, .transcribing, .cleaningTranscript, .pasting:
            return .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
        default:
            return nil
        }
    }

    var body: some View {
        Group {
            if let symbol {
                // SF Symbol — used only for `mic.fill` (recording) and
                // `mic.slash` (error). Branch is fine here because it's
                // inside the same concrete view; SwiftUI re-renders the
                // body but does not discard the view's identity.
                Image(systemName: symbol)
                    .resizable()
                    .scaledToFit()
            } else {
                // Brand asset — Comet handheld-mic silhouette. Template-
                // rendered so macOS tints it to the menu-bar foreground
                // colour (light/dark adaptive).
                Image("MenuBarIcon")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            }
        }
        .frame(width: 16, height: 16)
        .foregroundStyle(tint)
        .opacity(iconOpacity)
        .scaleEffect(iconScale)
        .animation(animation, value: isAnimating)
        .onAppear { isAnimating = true }
        .accessibilityLabel("Comet")
    }
}
