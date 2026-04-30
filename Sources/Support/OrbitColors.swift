import SwiftUI

/// Orbit brand palette. Mirrors the indigo scale used on
/// get.yourorbit.team — primary `#6366F1` is the canonical Orbit accent
/// and replaces the orange tint inherited from upstream Whispur.
///
/// Usage convention:
///   - `.orbit` for primary brand accents (button tints, progress bars,
///     active-state backgrounds, selected-tab highlights, link colour)
///   - `.orbitHover` for hover/pressed states on those same elements
///   - `.orbitMuted` for low-emphasis brand backgrounds (e.g. selected
///     tab fill at low opacity)
///
/// Semantic colours (`.orange` for warnings, `.red` for errors, `.green`
/// for success, `.yellow` for caution) are kept as-is — those communicate
/// state, not brand. Don't replace them with `.orbit`.
extension Color {
    /// Primary Orbit indigo — `#6366F1` in get-orbit's CSS.
    static let orbit = Color(red: 0x63 / 255, green: 0x66 / 255, blue: 0xF1 / 255)

    /// Hover / pressed variant — `#4F46E5` in get-orbit's CSS.
    static let orbitHover = Color(red: 0x4F / 255, green: 0x46 / 255, blue: 0xE5 / 255)

    /// Lighter accent used on dark backgrounds — `#818CF8`.
    static let orbitLight = Color(red: 0x81 / 255, green: 0x8C / 255, blue: 0xF8 / 255)

    /// Pale variant for subtle backgrounds — `#A5B4FC`.
    static let orbitMuted = Color(red: 0xA5 / 255, green: 0xB4 / 255, blue: 0xFC / 255)
}
