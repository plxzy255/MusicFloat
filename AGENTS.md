# MusicFloat Agent Notes

MusicFloat is a native macOS menu bar app for floating, translated music lyrics. The project is intentionally starting small: keep the first slices architectural, observable, and easy to reverse while leaving room for deeper Apple Music and Music.app experiments later.

## Product Direction

- Build a no-Dock menu bar app with a lightweight floating lyrics overlay.
- Prefer native macOS behavior over web-style UI or heavy custom surfaces.
- Keep the overlay fast, calm, readable, and always useful while music is playing.
- Treat translations as a first-class feature, but do not wire network translation until the app shell, provider boundaries, and cache strategy are ready.
- Do not pretend public Apple APIs expose synced Apple Music lyrics. Future lyric work must be explicit about source, permissions, and reliability.

## Reference App

Use `/Users/psp/Development/PlayStatus` as an important reference, especially for:

- menu bar app ergonomics,
- now-playing provider shape,
- AppleScript/Music and Spotify experiments,
- artwork and media caching ideas,
- lyrics UI states,
- detached or floating surface behavior,
- memory reduction when hidden surfaces unload.

MusicFloat should not become a copy of PlayStatus. The goal is to make this app more native, smaller at rest, more lyrics-focused, more translation-aware, and more experimental behind clean boundaries.

## Current Architecture

The active first slice is:

- `MusicFloat/App/AppState.swift`: app-wide observable state.
- `MusicFloat/App/MusicFloatApp.swift`: menu bar and settings scenes.
- `MusicFloat/MenuBar/MenuBarView.swift`: commands only.
- `MusicFloat/Overlay/FloatingPanelController.swift`: the only long-lived `NSPanel` owner.
- `MusicFloat/Overlay/LyricsOverlayView.swift`: mocked lyric and translation overlay.
- `MusicFloat/Settings/SettingsView.swift`: placeholder configuration surface.
- `MusicFloat/Diagnostics/AppTelemetry.swift`: stable unified logging categories.
- `MusicFloat/Player`: now-playing value types plus `MusicAppBridge`.
- `MusicFloat/Player/PlayerController.swift`: mock playback refresh boundary for proving state flow without real polling.
- `MusicFloat/Lyrics`: lyric value types, provider contract, and sync engine.
- `MusicFloat/Translation`: translation provider contract and mock translation payloads.
- `MusicFloat/Cache`: placeholder cache contract for later bounded memory/disk policy.
- `MusicFloat/Runtime`: feature flags, provider runtime state, and provider task ownership.

SwiftUI views should receive state and commands. They should not own AppKit windows, music bridges, provider clients, or long-lived caches.

## Future Boundaries

When adding real functionality, prefer these seams:

- `Player/MusicAppBridge.swift`: now-playing and playback commands. Start public-first, then add experimental adapters behind flags.
- `Player/PlayerController.swift`: task ownership for refresh loops. Keep real polling intervals adaptive and cancellable.
- `Lyrics/LyricsProvider.swift`: lyric lookup and attribution. Never assume MusicKit exposes synced lyrics.
- `Lyrics/LyricsSyncEngine.swift`: timing and active-line selection. Keep high-frequency ticks away from broad SwiftUI invalidation.
- `Translation/TranslationProvider.swift`: translation requests and cache keys. Do not log raw provider lyrics or personal listening history.
- `Cache/MediaCache.swift`: artwork, lyrics, translations, and bounded memory/disk policy. Keep disk cache opt-in and measured.
- `Runtime/ProviderPipelineController.swift`: owns provider tasks for the overlay. Keep loading cancellable and tied to visibility unless a feature flag explicitly allows hidden refresh.
- `Runtime/RuntimeFeatureFlags.swift`: declares whether a boundary is mock, public Apple API, experimental, or disabled. Architecture slices should default to mock-only with hidden refresh disabled.

Keep experimental adapters behind protocols and feature flags. AppleScript, ScriptingBridge, Accessibility, app observation, private-ish inspection, and provider scraping must stay replaceable and easy to disable.

## Telemetry

Use Apple's unified logging via `Logger`; do not use `print` for app telemetry.

Use categories consistently:

- `Lifecycle`
- `MenuBar`
- `Windowing`
- `Settings`
- `Performance`

Log stable, high-signal events: app launch, menu actions, panel creation/show/hide, settings appearance, future provider milestones, cache eviction, and fallback paths. Do not log secrets, tokens, raw lyrics from real providers, or personal listening history beyond coarse public-safe state.

Use `AppTelemetry.measure` for short performance spans that should show up as signposts in Instruments, especially panel creation/show/hide, provider calls, lyric sync ticks, cache reads, translation requests, and startup work. Keep signposts coarse; they are for finding shape, not narrating every line of code.

Run telemetry with:

```sh
./script/build_and_run.sh --telemetry
```

Run a memory sample with:

```sh
./script/build_and_run.sh --memory
```

For Xcode-native profiling, use Product > Profile on the shared scheme or use:

```sh
./script/profile.sh list
./script/profile.sh record "Time Profiler" 20s
./script/profile.sh record "Allocations" 30s
./script/profile.sh record "Logging" 15s
./script/profile.sh record "System Trace" 5s
```

For a local self-install style Release bundle, use:

```sh
script/release_self.sh --memory
script/release_self.sh --install
```

The self-release script exports `dist/MusicFloat.app`, keeps dSYM output in DerivedData, verifies `LSUIElement`, prints signing/entitlements, and builds with strip/postprocess plus coverage instrumentation disabled. Do not commit `dist/`.

The most useful Instruments templates for this project are:

- `App Launch`: startup cost and accidental eager initialization.
- `Time Profiler`: CPU cost from polling, sync engines, parsing, translation, or UI updates.
- `Allocations`: memory growth after overlay/settings/provider use.
- `Leaks`: retained windows, providers, caches, or translation clients.
- `SwiftUI`: expensive view invalidation and body recomputation.
- `Swift Concurrency`: task lifetimes, actor hops, and runaway async work.
- `Logging`: unified logs plus signposts from `AppTelemetry.measure`.
- `System Trace`: CPU wake/context-switch evidence, especially for hidden menu bar idle checks.
- `Power Profiler`: long-running menu bar idle cost.
- `Animation Hitches`: overlay movement/material/rendering smoothness.

## Build And Runtime Baseline

- Project type: Xcode macOS app.
- Scheme: `MusicFloat`.
- Bundle ID: `cv.MusicFloat`.
- The app is an agent-style UI element app: `LSUIElement = YES`.
- Keep Swift 6, strict concurrency, strict memory safety, and `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- Keep sandbox and hardened runtime on until a specific integration proves it needs a narrow entitlement change.
- Add usage strings only when the corresponding API is actually wired.
- Avoid broad permissions, Apple Events exceptions, Accessibility prompts, or network clients in architecture-only slices.

Use:

```sh
./script/build_and_run.sh --verify
```

before handing off meaningful app changes.

## Memory And Performance Expectations

A bare SwiftUI/AppKit menu bar process can sit around tens of MB of RSS because loading AppKit, SwiftUI, dyld shared cache mappings, and the Swift runtime has a non-zero floor. Treat around 20 MB RSS as a baseline to measure, not automatically a leak.

Before optimizing memory:

- measure Debug and Release separately,
- measure at rest, after showing the overlay, after hiding it, and after opening settings,
- distinguish resident memory from virtual memory,
- avoid loading artwork, lyric providers, translation clients, large caches, or heavy settings trees at startup.

Prefer lazy allocation. The floating panel, provider adapters, caches, translation clients, and experimental observers should initialize only when needed.

Hidden UI should not keep preview or provider clocks alive. Mock playback is allowed to advance while the overlay is visible or while a developer explicitly starts the mock preview, but hiding the overlay should cancel that task. Prefer adaptive lyric-boundary wakeups over one-second polling; if hidden providers later need background refresh, make the interval adaptive, feature-flagged, and measurable in System Trace/Power Profiler.

## Style

- Keep first-screen UI functional, not a landing page.
- Prefer system materials, standard controls, and macOS idioms.
- Use AppKit only where SwiftUI does not model the behavior cleanly.
- Keep each slice small enough to revert if an Apple API direction proves wrong.
