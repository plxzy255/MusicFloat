# Reference Comparison - 2026-05-25

## Summary

MusicFloat should use the reference apps as a source of targeted patterns, not as architecture to copy. The strongest reference is PlayStatus for bounded caches, status/popover lifecycle lessons, hidden-surface unloading, and window placement clamping. The `.tmp` Apple Music lyric repos are useful for endpoint/header corroboration and TTML/parser ideas, but they are brittle and often web-oriented. LyricFever is most useful as a cautionary contrast: it has useful provider concepts, but its global model and dependency footprint are heavier than MusicFloat should become.

## PlayStatus

### What To Borrow

Bounded persistent cache strategy.

- PlayStatus `PersistentMediaCache.swift:101-126` defines byte caps, entry caps, and TTLs.
- It distinguishes available lyrics TTL from unavailable lyrics TTL.
- It supports lyrics, artwork, animated artwork metadata, usage text, and clear-cache behavior.

Why it fits MusicFloat:

- MusicFloat already has `MediaCache.swift` as a placeholder.
- MusicFloat should eventually cache lyrics, translations, artwork, and catalog results.
- The project direction says disk cache should be opt-in and measured; PlayStatus shows a concrete shape without requiring MusicFloat to copy all product behavior.
- 2026-05-25 follow-up: MusicFloat now has an opt-in `DiskBackedMediaCache`
  for artwork/translation payloads plus Settings usage and Clear Cache controls.
  Raw lyrics remain memory-only until a separate privacy decision.

Inflight de-dupe and negative cache.

- PlayStatus `LyricsService.swift:21-134` keeps an actor, memory cache, disk cache, and `inflight` task dictionary.
- It stores unavailable results with a shorter TTL.

Why it fits MusicFloat:

- MusicFloat already guards stale results at the pipeline level.
- The next improvement is avoiding repeated equivalent provider work, especially for misses.

Window placement and clamping.

- PlayStatus `StatusBarController.swift:667-752` contains detached window placement and visible-screen clamping.

Why it fits MusicFloat:

- MusicFloat has a cleaner `FloatingPanelController`; placement/clamping belongs there.
- Borrow the idea, not the surrounding popover/player surface.

Hidden surface unloading.

- PlayStatus unloads hidden surfaces in its status controller path.
- MusicFloat already has `reduceHiddenMemoryUsage`, but provider pipeline/cache release can be stricter.

Settings affordances.

- PlayStatus exposes cache usage and clear-cache controls.
- It also has a "Reduce Hidden Memory Usage" style preference.

Why it fits MusicFloat:

- MusicFloat already has a reduce-hidden-memory preference.
- Cache usage and clear-cache now exist for the opt-in disk cache path; keep the
  surface small and avoid expanding it into a PlayStatus-style media dashboard.

### What Not To Borrow

Do not copy the richer variable-width menu bar item.

- MusicFloat's square image-only status item is calmer and more native for a focused lyric overlay.
- PlayStatus's text/marquee/status width behavior is product-appropriate for a now-playing app, not necessarily for MusicFloat.

Do not copy broad feature surface.

- PlayStatus has more media caching, artwork, settings, detached windows, controls, and product surface.
- MusicFloat should remain smaller and more lyrics/translation focused.

## LyricFever

### Useful Ideas

Provider protocol shape.

- LyricFever has provider protocols and multiple lyric providers.
- This validates MusicFloat's direction of keeping lyric sources behind contracts.

Search/provider variety.

- LyricFever uses LRCLIB, NetEase, Spotify-style paths, and user search surfaces.
- Some ideas may become useful if MusicFloat later adds manual lyrics search.

### Cautions

Global observable app model is too heavy for MusicFloat.

- LyricFever `ViewModel.swift` is a broad `@Observable` singleton tying player state, providers, tasks, CoreData, analytics, and UI concerns together.
- MusicFloat should keep `AppState` narrow where possible and keep providers/cache/task ownership outside views.

Dependency footprint is not aligned with the first slice.

- LyricFever pulls in analytics, CoreData, WebKit, MediaRemote-style adapters, keyboard shortcuts, and multiple network providers.
- MusicFloat should stay public-first and feature-flag experimental/private-ish integrations.

Logging and privacy posture are weaker.

- LyricFever uses prints and provider names/raw metadata in places.
- MusicFloat should keep unified logging and privacy-safe fields.

## Manzana Apple Music Lyrics

### Useful Ideas

Endpoint/header corroboration.

- Manzana confirms media-user-token handling and Apple Music web API lyric endpoint families.
- It uses broad song include shapes with lyrics and syllable lyrics.

### Cautions

Not a native app architecture reference.

- It is a Python/API-oriented helper.
- It is useful for "this endpoint/header family has been seen elsewhere," not for product architecture.

Parser depth is weaker than MusicFloat's needs.

- Simple TTML-to-lyrics conversion is not enough for MusicFloat's timed/syllable/translation goals.

## apple-music-downloader

### Useful Ideas

Apple Music web lyric request details.

- `utils/lyrics/lyrics.go` confirms `syllable-lyrics` and `extend=ttmlLocalizations`.
- It uses Bearer authorization, Origin/Referer headers, and media-user-token cookie handling.

Catalog metadata fields.

- `utils/ampapi/song.go` exposes fields like `hasTimeSyncedLyrics`, `hasLyrics`, and `audioLocale`.

Why it fits MusicFloat:

- MusicFloat already uses the endpoint family.
- Next catalog resolver improvements can use lyric availability and locale metadata to avoid bad matches.

### Cautions

Downloader assumptions do not equal menu bar app assumptions.

- It can demand token/config setup and batch process media.
- MusicFloat should keep token use explicit, local, and user-controlled.

Do not overfit to downloader-specific language handling.

- CJK and LRC formatting utilities are useful examples, but MusicFloat needs native UI state and translation cache semantics.

## YouLyPlus

### Useful Ideas

Dedicated syllable lyric endpoint.

- `src/inject/applemusic/songTracker.js` uses `/songs/{id}/syllable-lyrics` with `extend=ttmlLocalizations`.
- It checks Apple Music page metadata before fetching.

Frame-based lyric sync concept.

- Web code uses animation frames to keep visual sync smooth.

### Cautions

Browser extension architecture does not transfer directly.

- It injects DOM scripts, observes styles, and runs in the Apple Music web player context.
- MusicFloat must stay native and should not import DOM/watchdog patterns.

The transferable idea is lifecycle cleanup.

- High-frequency visual sync should start only while visible/playing and stop cleanly when hidden.
- MusicFloat already follows this direction with hidden live tick cancellation.

## applemusic-like-lyrics

### Useful Ideas

TTML parser/test mindset.

- The `packages/ttml` code has parser abstractions, DOMParser injection, metadata/sidecar handling, and broad tests.
- This is a good reference for richer TTML parsing features, not necessarily for direct code reuse.

Rendering lifecycle principles.

- The docs advise frame-based progress and explicit disposal of loops/listeners when unmounted.

Why it fits MusicFloat:

- MusicFloat can use the same principle: progress rendering should be visible-only and narrow.
- Future TTML parser tests can look at metadata, localizations, agents, sidecar/transliteration fields, and round-trip cases.

### Cautions

Browser rendering is not native rendering.

- React/Vue/canvas/WebGL patterns should not drive MusicFloat UI architecture.
- MusicFloat should use SwiftUI/AppKit and profile actual macOS hitches.

## Cross-Reference Conclusions

MusicFloat is already stronger than the references in these ways:

- Cleaner provider/task boundaries than LyricFever.
- Better profiling/reporting discipline than PlayStatus or `.tmp` repos.
- Better first-slice native focus than web-player lyric projects.
- Explicit feature flags and mock/live boundaries.
- Stronger stale-result and hidden-work cancellation than many reference paths.

The best borrow list:

1. PlayStatus bounded cache and clear-cache affordances.
2. PlayStatus inflight de-dupe and unavailable-result TTL.
3. PlayStatus detached window placement/clamping.
4. apple-music-downloader catalog metadata fields for matching and availability checks.
5. YouLyPlus dedicated syllable endpoint corroboration.
6. applemusic-like-lyrics TTML parser/test coverage ideas.

The best avoid list:

1. LyricFever global all-in-one `ViewModel`.
2. LyricFever analytics/print-heavy provider flow.
3. PlayStatus rich status item/player UI as a default MusicFloat surface.
4. Web extension DOM injection and CSS watchdog patterns.
5. Treating Apple Music web endpoints as stable public APIs.

## Recommended Reference-Driven Slices

Slice 1 - Cache contract:

- Design MusicFloat cache keys for lyrics, translations, artwork, catalog IDs, and misses.
- Use PlayStatus TTL/cap ideas, but keep disk cache opt-in.

Slice 2 - Catalog robustness:

- Add metadata-aware Apple Music catalog scoring using lyric availability and locale fields.
- Cache failures briefly.

Slice 3 - Panel placement:

- Borrow PlayStatus clamping idea into `FloatingPanelController`.
- Persist placement only after manual movement is supported.

Slice 4 - TTML coverage:

- Add parser fixtures for localizations, syllables, line timing, translations/transliterations if present, and malformed docs.

Slice 5 - Renderer proof:

- Use SwiftUI/Time Profiler traces to decide whether the current progress mask approach is enough.
- Avoid importing browser renderer structure.
