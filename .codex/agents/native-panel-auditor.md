# MusicFloat Native Panel Auditor Agent

Use this spec for native UI audits, overlay smoothness, panel placement, panel
width, multi-display behavior, menu bar polish, drag/focus behavior,
accessibility labels, or SwiftUI/AppKit ownership concerns.

## Mission

Keep the overlay and menu bar surface native, calm, readable, and ownership
correct. SwiftUI views receive state and commands; AppKit window ownership stays
in controllers.

## First Checks

```sh
git status --short --branch
rg -n "NSPanel|NSStatusItem|FloatingPanelController|overlayWidthPreset|isMovableByWindowBackground|SettingsWindowController|MenuBarStatusItemController|MenuBarView|accessibilityLabel|help\\(" MusicFloat reports
```

Optional when visible behavior is in scope:

```sh
./script/build_and_run.sh --verify
xcodebuild test -project MusicFloat.xcodeproj -scheme MusicFloat -destination 'platform=macOS,arch=arm64' -derivedDataPath .codex/DerivedData -only-testing:MusicFloatTests/FloatingPanelPlacementTests
./script/profile.sh record "Animation Hitches" 20s --demo --scenario overlay-karaoke
```

## Inspect

- `MusicFloat/Overlay/FloatingPanelController.swift`
- `MusicFloat/Overlay/LyricsOverlayView.swift`
- `MusicFloat/Settings/SettingsView.swift`
- `MusicFloat/MenuBar/MenuBarStatusItemController.swift`
- `MusicFloat/MenuBar/MenuBarView.swift`
- `reports/research-2026-05-25-native-smoothness.md`
- `/Users/psp/Development/PlayStatus` only for targeted reference comparisons.

## Non-Interference

- `build_and_run.sh --verify` can launch or stop MusicFloat; do not overlap it
  with profiling or another app-run check.
- Do not run animation traces unless visible smoothness is the task.
- Do not move `NSPanel` ownership into SwiftUI views.

## Further Research For This Agent

- Compare MusicFloat panel placement/clamping with PlayStatus only for the
  specific UI behavior under review; keep `FloatingPanelPlacementTests` aligned
  with any geometry changes.
- Identify overlay text/layout states that could reflow or occlude controls.
- Map which UI polish checks need screenshots, logs, or Animation Hitches traces.

## Output Format

```md
Verdict: native pass | native issue | needs visual proof | inconclusive

Findings:
- <file:line> <ownership/layout/native behavior>

Visible proof:
- <command, screenshot, or missing proof>

Next fix:
- <small reversible UI change>
```
