# Changelog

## [0.2.6] — 2026-05-01

### Fixed

* **Right Option (and any modifier-only hotkey) now actually triggers hold-to-talk.** Bindings whose key code is itself a modifier (Right Option, Right Command, etc.) were silently failing because the matcher only checked the regular pressed-keys set; modifier key codes flow through `flagsChanged` and live in a separate set. Same fix unblocks any future modifier-only binding.
* **Menu-bar icon no longer disappears shortly after launch.** SwiftUI's `MenuBarExtra` was discarding the underlying `NSStatusItem` when the label view re-evaluated — the label held reactive dependencies (`@AppStorage`, `@Environment(\.openWindow)`, `.onReceive`, `.task`) and switched between distinct concrete view types per pipeline phase. Label is now a single concrete view driven solely by phase; side effects moved to the popover content and to `AppDelegate`.

### Added

* **Right Command** as a hold-to-talk preset alongside Right Option, Fn, Control + Space, and F5.

### Internal

* `comet://` URL scheme registered for AppKit-to-SwiftUI scene routing (replaces the notification-via-label hack the old menu-bar code relied on for opening Settings at launch).

## [0.1.0] — 2026-04-30

Initial Comet release. Forked from [Whispur](https://github.com/sophiie-ai/whispur) at v0.13.4.

### Branding

* Application name: Comet
* Bundle identifier: `team.yourorbit.OrbitDictation`
* App icon, menu bar glyph, and Settings/About surfaces rebranded for Orbit
* Application Support directory and Keychain service rescoped under the Orbit identifier so installations do not collide with upstream Whispur

### Cleanup prompt

* New default cleanup prompt: strict text-post-processor contract that refuses to act on the transcript content even when it reads like an instruction
* Adds proper-noun preservation, sentence-boundary inference, English-first language scope, sharper number-normalization rules, hallucination guard for repeated-sentence STT artefacts, list rule that requires three or more items, and explicit "no Markdown unless dictated" rule

### Distribution

* Sparkle update channel points to GitHub Releases on this fork
* Distributed from the Orbit Downloads page on get.yourorbit.team
