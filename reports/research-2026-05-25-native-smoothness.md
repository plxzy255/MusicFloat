# Native Smoothness Audit - 2026-05-25

## Summary

MusicFloat is already pointed in the right native direction: it uses an AppKit `NSStatusItem`, keeps `FloatingPanelController` as the single long-lived panel owner, keeps provider clients outside SwiftUI views, and cancels live ticks when the overlay is hidden. The most important native-smoothness work is not a visual redesign. It is making launch idleness explicit, keeping floating-panel placement/size behavior stable, and narrowing high-frequency lyric progress updates so the overlay feels smooth without broad app invalidation.

## 2026-05-25 Follow-up Implementation Status

Closed in the same-day implementation batch:

- Normal launch now stays as a quiet menu-bar app; `--demo` and `--live` are the
  explicit auto-start paths.
- Overlay width changes now resize and clamp the existing `NSPanel` instead of
  waiting for the next show.
- The overlay now restores its last origin, chooses the active display for
  first placement, clamps on resize/show/display changes, and has focused
  placement unit tests.
- Long current-track menu text is truncated with the full value kept in the
  tooltip.
- Settings language loading is tied to SwiftUI `.task`.

Still open:

- Drag/control hit-test behavior still needs manual QA once movement and scrubs
  are exercised together.
- SwiftUI body recomputation during syllable-heavy live playback still needs a
  SwiftUI, Animation Hitches, or Time Profiler run before deeper overlay
  rendering changes.
- Follow-up narrowed the overlay rendering model: non-syllable lines no longer
  receive fake karaoke progress, untimed documents advance by equal estimated
  line windows instead of word-weighted slots, line-window transitions are
  simple crossfades instead of moving rows, and per-tick syllable progress no
  longer restarts a SwiftUI animation on every clock update.
- Live visible-lyrics/AX refresh is no longer attached to each high-frequency
  lyric clock tick. `MusicFloatAppController` now owns a separate visible-only
  refresh loop, so `PlayerController` ticks only advance elapsed time and handle
  seek/watchdog resync.
- Clean driven live sample `20260525-142048Z-live-Direct-Sample-52adb7a`
  validated the visible live path after those changes: playback, overlay,
  provider readiness, non-mock Apple Music web lyrics, one watchdog seek, one
  resync, and one track change all passed from a clean snapshot. It reported
  avg CPU 5.15 percent and max CPU 23.5 percent, which is useful smoke evidence
  but not a SwiftUI or Animation Hitches proof.

## Current Strengths

AppKit status item is the right active menu surface.

- `MusicFloat/MenuBar/MenuBarStatusItemController.swift:26-55` uses `NSStatusItem.squareLength`, an image button, and on-demand `NSMenu`.
- This is better suited to a lyrics utility than a text-heavy status item.
- PlayStatus has richer variable-width player/menu behavior; that is useful as a reference, but MusicFloat should stay quieter.

Single panel owner is clean.

- `MusicFloat/Overlay/FloatingPanelController.swift:5-45` centralizes `NSPanel` lifetime.
- SwiftUI views receive state/commands rather than owning the panel.
- This is cleaner than reference approaches where SwiftUI modifiers own panels.

Hidden overlay work is already treated seriously.

- `MusicFloat/Player/PlayerController.swift:256-379` stops live ticking when the overlay is hidden and sleeps toward lyric boundaries.
- `MusicFloat/App/AppState.swift:586-590` keeps high-frequency elapsed-time mutation separate from stable player state.
- `MusicFloat/Runtime/ProviderPipelineController.swift:350-430` cancels hidden work and translation tasks.

Overlay controls are native enough for the current slice.

- `MusicFloat/Overlay/LyricsOverlayView.swift:183-281` uses icon buttons with help/accessibility labels.
- `MusicFloat/Overlay/LyricsOverlayView.swift:291-323` has direct scrub handling.
- The layout is compact and functional rather than a landing page or decorative shell.

## Findings

### NATIVE-001: Initial default launch opened live overlay

Evidence:

- `MusicFloat/App/MusicFloatApp.swift:70-88` schedules live startup after launch unless `--demo` is passed.
- `MusicFloat/App/MusicFloatApp.swift:164-200` starts live Apple Music, shows the overlay, primes playback state, and may load lyrics/artwork.
- `AGENTS.md` says the app should stay small at rest and allocate lazily.

Impact:

- The app behaves like an active demo/live tool on normal launch rather than a calm menu bar utility.
- This makes idle memory, wakeups, permissions, and Music.app side effects harder to reason about.
- It also makes "app launched successfully" and "live pipeline works" less distinct for future agents.

Recommendation:

- Make normal launch menu-bar idle.
- Reserve auto overlay/live startup for `--demo`, a future explicit `--live`, or a persisted opt-in.
- Keep test/demo entry points easy, but make "at rest" a real state that can be profiled.

### NATIVE-002: Panel placement is one-shot and not persisted

Evidence:

- `MusicFloat/Overlay/FloatingPanelController.swift:102-108` places the overlay from `NSScreen.main?.visibleFrame`.
- There is no persisted origin, active-screen selection, or clamping after display changes.
- PlayStatus has useful placement/clamping logic in `StatusBarController.swift:667-752`.

Impact:

- Users with multiple displays, changing Spaces, or external monitors can get surprising placement.
- A panel can feel less native if it does not remember where the user put it.

Recommendation:

- Persist the overlay origin once manual movement is supported.
- Clamp the frame to the active/containing screen visible frame on show, resize, and display changes.
- Prefer keeping this logic inside `FloatingPanelController`, not in SwiftUI views.

Follow-up status:

- Implemented in `FloatingPanelController` with origin persistence, active-screen
  first placement, resize/show/display-change clamping, and focused
  `FloatingPanelPlacementTests`.
- Remaining proof is manual multi-display QA with the real app because unit
  tests cover geometry, not macOS Spaces/display behavior.

### NATIVE-003: Overlay width changes can leave the panel frame stale

Evidence:

- `MusicFloat/Overlay/FloatingPanelController.swift:28` applies size during `show()`.
- `MusicFloat/Overlay/FloatingPanelController.swift:49-50` computes panel size from `appState.overlayWidthPreset`.
- `MusicFloat/Settings/SettingsView.swift:184` writes width preference changes.
- The settings-change callback in `MusicFloat/App/MusicFloatApp.swift:234` refreshes translation, but does not visibly resize the panel.

Impact:

- Changing width in Settings while the overlay is visible may update SwiftUI content assumptions without updating the actual AppKit panel frame.
- This can produce clipped, cramped, or oddly spaced overlay content.

Recommendation:

- Add a future panel `updateLayout` or `applySizeAndClamp` method.
- Call it when the width preset changes while the panel exists.
- Measure before/after with screenshots or preview snapshots, because the visible failure is layout behavior rather than a unit-test-only contract.

### NATIVE-004: Draggable background and controls need a deliberate contract

Evidence:

- `FloatingPanelController` makes the panel borderless, floating, non-activating, and movable by background.
- `LyricsOverlayView` also has sliders and icon buttons.
- PlayStatus has a small AppKit bridge (`DetachedWindowDragSupport`) for avoiding drag/control fights.

Impact:

- Controls can feel "slippery" if drag gestures and sliders/buttons compete.
- A nonactivating floating utility should feel stable under repeated scrubbing and volume changes.

Recommendation:

- Keep `FloatingPanelController` as owner.
- If controls fight drag behavior, borrow the PlayStatus idea: an AppKit bridge that toggles or scopes movable-by-background behavior around interactive controls.
- Add a short manual QA checklist: drag panel, scrub, adjust volume, click next/previous, use fullscreen Space.

### NATIVE-005: Menu item text can grow too long

Evidence:

- `MusicFloat/MenuBar/MenuBarStatusItemController.swift:78` includes current track text in the menu.
- The macOS SwiftUI/AppKit guidance for menu-bar utilities favors short labels and predictable command rows.
- The prior menu-warning memory for this repo says row churn was a real source of AppKit warnings.

Impact:

- Very long track labels can make the menu feel less native and can cause row width churn.
- Even if not a crash bug, it makes the menu look less polished.

Recommendation:

- Keep the status item image-only.
- Truncate long current-track menu labels, and expose full metadata in a disabled submenu, tooltip, or Settings/diagnostics surface if needed.
- Keep placeholder rows stable so tracked menus do not reshuffle while open.

### NATIVE-006: Overlay progress rendering deserves SwiftUI profiling, not guessing

Evidence:

- `MusicFloat/App/AppState.swift:443-462` builds `overlaySnapshot` from multiple state pieces.
- `MusicFloat/Overlay/LyricsOverlayView.swift:461-484` animates line window changes.
- `MusicFloat/Overlay/LyricsOverlayView.swift:537-681` uses a `GeometryReader` overlay/mask technique for timed lyric progress.
- `MusicFloat/Player/PlayerController.swift:21` caps syllable ticks at 0.12 seconds.
- Follow-up removed the provider/AX refresh callback from the live lyric tick,
  so the remaining high-frequency work is visual elapsed-time state rather than
  provider probing.
- Clean driven live sample `20260525-142048Z-live-Direct-Sample-52adb7a`
  confirmed a visible live session, seek resync, track change, and non-mock
  Apple Music web lyrics from a clean snapshot. It was a direct usage sample
  with no SwiftUI, Animation Hitches, Time Profiler, screenshot, or video
  artifact, and the applied document had `syllable_count=0`.

Impact:

- The current design is plausible, but it may do more SwiftUI body work than needed during syllable-heavy songs.
- The right fix depends on live SwiftUI trace evidence, not taste.

Recommendation:

- Run same-mode SwiftUI, Animation Hitches, or Time Profiler profiling on a
  syllable-heavy live track before changing rendering.
- If body recomputation is high, introduce a narrower overlay clock/progress model or precomputed timing cursor.
- Keep broad `AppState` invalidation away from per-syllable progress where possible.
- Keep provider/AX refresh on its separate visible-only lane; do not reattach it
  to the live tick callback.

### NATIVE-007: Settings language loading should be tied to view lifecycle

Evidence:

- `MusicFloat/Settings/SettingsView.swift:171` starts language loading from `onAppear`.
- `MusicFloat/Settings/SettingsView.swift:218-271` loads supported translation languages.

Impact:

- Minor today, but unstructured tasks in settings can outlive the view or duplicate work on repeated opens.

Recommendation:

- Use `.task` or explicit cancellable task ownership for the language list.
- Cache the language list in a runtime/provider state object if Translation remains enabled by default.

## Native Work To Keep

- Keep `NSStatusItem` AppKit-first.
- Keep `FloatingPanelController` as the only long-lived `NSPanel` owner.
- Keep `LyricsOverlayView` focused on view composition and commands.
- Keep provider and cache ownership outside SwiftUI.
- Keep hidden overlay behavior measured and cancellable.

## Native Work To Avoid

- Do not add a web-style dashboard or heavy settings surface to solve overlay polish.
- Do not let SwiftUI views create panels directly.
- Do not import PlayStatus's full menu/player surface; borrow only targeted placement, cache, and lifecycle ideas.
- Do not add decorative complexity before the overlay has proven stable in live Apple Music scenarios.
