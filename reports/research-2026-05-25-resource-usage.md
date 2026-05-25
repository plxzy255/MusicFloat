# Resource Usage Audit - 2026-05-25

## Summary

MusicFloat already has unusually good profiling discipline for a young macOS
menu bar app: a run ledger, live verification rules, usage CSVs, trace disk
accounting, and a performance-flaw tracker. The initial resource concerns in
this snapshot were default startup work, Translation/NaturalLanguage linkage in
Release, MainActor-bound parsing, retained live provider/cache state after stop,
and missing bounded/negative cache behavior. Same-day follow-up work addressed
several of those; the status block below is the current map.

## 2026-05-25 Follow-up Implementation Status

Same-day follow-up work closed several items from this snapshot:

- Normal launch is now the idle menu-bar path; `--demo` and `--live` are the
  explicit auto-start modes.
- Default Release no longer links Translation/NaturalLanguage frameworks.
- Apple Music web JSON decode, catalog search decode, TTML parse, LRCLIB decode,
  and LRCLIB parse moved out of broad MainActor work through
  nonisolated/detached helpers.
- Stopping live Apple Music can release the live provider pipeline when reduced
  hidden memory mode is enabled.
- Public lyrics lookup now has bounded positive caching, short confirmed-miss
  negative caching, in-flight de-dupe, and tests for transient-failure
  non-poisoning. Apple Music catalog true misses also get short-term backoff,
  while transient catalog resolution failures throw through to prevent
  top-level negative-cache poisoning.
- The shared `EphemeralMediaCache` now enforces entry count, estimated byte
  budget, namespace TTLs, short unavailable TTL, and LRU eviction, with focused
  tests.
- Successful runtime translations are now cached through the bounded ephemeral
  cache using privacy-safe document/provider/target keys. Cache keys include
  lyric content in a one-process hash only; raw lyric text is not exposed in the
  key string or logs.
- Live artwork refresh now stores downsampled artwork data in the same bounded
  ephemeral cache behind privacy-safe hashed track keys, avoiding repeated
  Music.app artwork fetch/downsample work for the same track.
- Live visible-lyrics / AX refresh is now decoupled from the high-frequency
  lyric clock tick. The playback tick advances elapsed time and seek/watchdog
  state only; provider/AX refresh runs on its own visible-overlay loop.
- The shared cache now has an opt-in disk-backed wrapper for artwork and
  translation payloads, Settings exposes memory/disk usage, and Clear Cache
  removes both memory entries and disk files. Disk filenames and the index use
  hashed lookup keys rather than raw track or lyric strings.
- `script/profile.sh` now has an explicit `--apple-translation` profiling lane,
  run-ledger entries record `app.apple_translation_build`, strict comparisons
  reject mixed default/translation builds, and live ledger summaries include
  lookup/timeout correlation fields.
- `script/agent_verify.sh` now runs the full app handoff gate, and
  `script/profile.sh compare-runs --strict` rejects invalid comparisons.

Still open from a resource perspective:

- Live seek/scrub evidence now has one clean driven Music.app sample. Keep it
  fresh when playback-clock, sync-engine, or provider-refresh behavior changes.
- Clean same-mode startup/demo translation-enabled baselines exist; active
  translation-session baselines remain future. Disk persistence is now opt-in
  and still intentionally excludes raw lyrics until a separate privacy/product
  decision is made.

## Current Measurement Snapshot

Existing profiling commands:

- `./script/profile.sh report` reported 16 recorded runs.
- `./script/profile.sh disk` reported `.codex/traces` at 6.9 MB and DerivedData at 264 MB.

Recent run examples from the report:

- `20260525-051919Z-live-Direct-Sample-1d5470b`: live/apple-music-karaoke, avg RSS 129.6 MB, max CPU 17.6 percent.
- `20260525-052533Z-live-Direct-Sample-1d5470b`: live/apple-music-driven-karaoke, avg RSS 111.01 MB, max CPU 12.8 percent.
- `20260525-052748Z-live-Direct-Sample-1d5470b`: live/apple-music-karaoke-solitaires, avg RSS 107.9 MB, max CPU 24.8 percent.

Initial research-pass verification:

- Xcode build succeeded.
- All enabled tests in the initial pass passed.
- The then-existing Release binary linked `Translation.framework`,
  `_Translation_SwiftUI`, and `NaturalLanguage.framework`.

Follow-up verification after implementation:

- Focused provider-cache and Apple Music web tests passed.
- Focused artwork cache tests passed.
- Default Release build succeeded.
- `otool -L` on the fresh default Release binary produced no Translation or
  NaturalLanguage framework linkage.
- `script/agent_verify.sh` passed and reported the current profile ledger/disk
  state.
- Local-only smoke verification for the new translation-enabled lane passed
  with isolated artifacts:
  `RUN_LEDGER=/private/tmp/musicfloat-agent/profile-lane-smoke.jsonl
  TRACE_DIR=/private/tmp/musicfloat-agent/traces
  DERIVED_DATA_DIR=/private/tmp/musicfloat-agent/DerivedData
  ./script/profile.sh sample 5s --demo --apple-translation --scenario
  translation-enabled-smoke`. The smoke ledger row
  `20260525-074552Z-demo-Direct-Sample-28b81d4` recorded
  `app.apple_translation_build=true`, and `otool -L` on that isolated Release
  app showed `Translation.framework`, `_Translation_SwiftUI.framework`,
  `NaturalLanguage.framework`, and `libswiftNaturalLanguage.dylib`.
- Driven live run `20260525-080546Z-live-Direct-Sample-28b81d4` passed live
  verification with Music.app playback, live overlay, non-mock Apple Music web
  lyrics (`line_count=64`), provider readiness, and seek/track-change evidence.
  It reported avg RSS 113.69 MB, max RSS 116.39 MB, avg CPU 3.8 percent, max
  CPU 13.9 percent, two provider lookups, and `network_timeout_count=0`.
- Clean snapshot driven live run
  `20260525-142048Z-live-Direct-Sample-52adb7a` passed live verification from a
  temporary clean worktree snapshot. It reported avg RSS 111.28 MB, max RSS
  114.27 MB, avg CPU 5.15 percent, max CPU 23.5 percent, two provider lookups,
  one watchdog seek, one live-clock resync, one track change, and
  `network_timeout_count=0`.
- `script/profile.sh` timeout summarization now filters out AppleEvent timeout
  parameters such as `timeout 7200` so the live ledger only counts actual
  network/request timeout failures.

## Findings

### PERF-RESEARCH-001: Normal launch is not a true idle baseline

Follow-up status: closed for the default launch contract. Normal launch now
stays idle unless an explicit `--demo` or `--live` path is used. Future work is
to record a clean idle Release baseline.

Evidence:

- `MusicFloat/App/MusicFloatApp.swift:70-88` schedules live startup and overlay show shortly after launch.
- `MusicFloat/App/MusicFloatApp.swift:164-200` starts live Apple Music, shows panel, primes bridge state, and can load lyrics/artwork.
- `AGENTS.md` says hidden UI and provider clocks should not stay alive and that startup should avoid eager provider/cache/translation work.

Risk:

- Idle memory samples may include live provider, panel, artwork, and lyric pipeline work.
- This makes it harder to know the true AppKit/SwiftUI floor of the app.

Recommended next step:

- Establish three distinct modes in reports:
  - `idle`: menu bar item only, no overlay, no live provider.
  - `demo`: mock overlay and mock provider.
  - `live`: Apple Music bridge/provider active.
- Profile Debug and Release separately for each mode.

### PERF-RESEARCH-002: Initial Release linked Translation and NaturalLanguage

Follow-up status: closed for the default Release binary and tooling lane. The
fresh default Release build no longer links Translation/NaturalLanguage, and
`script/profile.sh --apple-translation` now provides an explicit separate lane
for measuring that framework cost.

Evidence:

- `MusicFloat.xcodeproj/project.pbxproj:245` defines `DEBUG ENABLE_APPLE_TRANSLATION`.
- `MusicFloat.xcodeproj/project.pbxproj:314` defines `ENABLE_APPLE_TRANSLATION` for Release.
- `otool -L .codex/DerivedData/Build/Products/Release/MusicFloat.app/Contents/MacOS/MusicFloat` showed:
  - `NaturalLanguage.framework`
  - `Translation.framework`
  - `_Translation_SwiftUI.framework`
- `reports/performance-flaws.md` says a prior Translation/NaturalLanguage startup-memory flaw was resolved by keeping Translation separately gated.

Risk:

- Release memory baselines may have regressed relative to the resolved performance-flaw note.
- Translation may be treated as default product behavior without the corresponding baseline, cache, and lifecycle decisions.

Recommended next step:

- Keep default Release and `--apple-translation` measurements separate in the
  ledger.
- Collect clean same-mode default-vs-translation baseline/candidate pairs when
  translation cost becomes the active question. Use `script/profile_snapshot.sh`
  for dirty-checkout candidates or a real clean branch/worktree; local dirty
  smoke runs prove the lane works but are not regression evidence.
- Follow-up collected a clean snapshot startup/demo pair at commit `8af2ba8`.
  Default run `20260525-082557Z-demo-Direct-Sample-8af2ba8` and Apple
  Translation run `20260525-082703Z-demo-Direct-Sample-8af2ba8` did not show a
  startup RSS jump from merely linking Translation/NaturalLanguage. Repeat once
  real translation work is active, because this pair does not measure an active
  `TranslationSession`.

### PERF-RESEARCH-003: Heavy parsing is effectively MainActor-bound

Follow-up status: partially closed. Apple Music web decode, catalog search
decode, TTML parse, and LRCLIB decode/parse now run through
nonisolated/detached helpers. Keep a syllable-heavy Time Profiler or SwiftUI run
as future evidence before claiming a measured hitch reduction.

Evidence:

- `MusicFloat.xcodeproj/project.pbxproj:359` and `:402` set `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- `MusicFloat/Lyrics/AppleMusicWebLyricsProvider.swift:10` is `@MainActor`.
- Apple Music JSON decode happens in the web provider path.
- TTML parsing starts in `MusicFloat/Lyrics/TTMLParser.swift`.

Risk:

- JSON/XML/LRC parse work can block the same actor responsible for UI state and overlay updates.
- Large TTML or rich syllable documents could show up as hitches even if network and provider order are correct.

Recommended next step:

- Move parse/decode into nonisolated helpers or a dedicated parsing actor.
- Keep only state application and logging on MainActor.
- Add a performance sample around a syllable-heavy track before and after.

### PERF-RESEARCH-004: Live provider store and lyrics cache stay retained after stop

Follow-up status: partially closed. Stopping live mode now releases the live
provider pipeline when reduced hidden memory mode is enabled. Follow-up profiling
should still compare rest, after live overlay, after hide, and after stop.

Evidence:

- `MusicFloat/App/MusicFloatApp.swift:270` keeps a lazy live provider pipeline store.
- `MusicFloat/Lyrics/LyricsProvider.swift:101-109` keeps a 64-entry memory cache.
- `MusicFloat/App/MusicFloatApp.swift:150` stops live mode by cancelling hidden work and flipping flags, but does not release the live provider pipeline/cache.

Risk:

- "Reduce hidden memory use" can release panel content, but the live provider stack and caches may remain resident after stopping live mode.
- This matters if Translation and lyric providers are heavy or if users open live mode briefly.

Recommended next step:

- Add a future release/reset path for the live provider pipeline when reduced-memory mode is enabled.
- Measure at rest, after live overlay, after hide, and after stop live.
- Treat provider/cache retention as intentional only if it has a clear speed benefit and a cap.

### PERF-RESEARCH-005: Cache layer is not yet bounded enough for real use

Follow-up status: substantially closed. Lyrics lookup now has bounded positive
cache, short confirmed-unavailable negative cache, and in-flight de-dupe. Apple
Music catalog true misses have short backoff. The shared ephemeral cache now has
entry, byte, TTL, unavailable-TTL, and LRU limits, and successful translations
plus downsampled artwork are wired through it with focused tests. The cache now
also has an opt-in disk-backed wrapper for artwork/translation payloads and
Settings usage/clear controls.

Evidence:

- `MusicFloat/Cache/MediaCache.swift` includes the ephemeral memory cache plus
  `DiskBackedMediaCache`, which persists only privacy-reviewed namespaces when
  explicitly enabled.
- `MusicFloatTests/MediaCacheTests.swift` covers expiration, unavailable TTL,
  LRU eviction, over-budget rejection, opt-in disk restore, disabled disk reads,
  clear-cache removal, and raw lookup-key privacy for disk filenames/indexes.
- `MusicFloatTests/AppStateArtworkTests.swift` covers artwork cache hits and
  privacy-safe artwork cache keys.
- Initial snapshot: `MusicFloat/Lyrics/LyricsProvider.swift:101-109` had an in-memory lyric cache with entry count but no TTL or persistent negative cache.
- PlayStatus `PersistentMediaCache.swift:101-126` has byte caps and TTLs.
- PlayStatus `LyricsService.swift:21-134` has inflight de-dupe and unavailable-result caching.

Risk:

- Repeated misses can repeat expensive work.
- Catalog failures, LRCLIB misses, and lyrics-unavailable cases have no durable backoff.
- Future cache integrations could still grow if they bypass the bounded cache
  contract, persist new namespaces without measurement, or store raw lyrics on
  disk before the privacy policy is explicit.

Recommended next step:

- Keep disk cache opt-in and route future cache namespaces through the bounded
  memory contract first.
- Measure disk-enabled artwork/translation behavior before adding lyrics disk
  persistence.
- Keep privacy-safe cache usage reporting at namespace/count/size level.

### PERF-RESEARCH-006: Live tick design is good, but can be cheaper

Evidence:

- `MusicFloat/Player/PlayerController.swift:21` caps syllable tick sleeps at 0.12 seconds.
- `MusicFloat/Player/PlayerController.swift:299-312` computes next lyric boundary repeatedly.
- `MusicFloat/Lyrics/LyricsSyncEngine.swift:36` scans/filters timing arrays.
- `MusicFloat/App/AppState.swift:586-590` updates elapsed time from MainActor.

Risk:

- The existing design is much better than one-second blind polling for lyric smoothness.
- However, repeated scanning and broad observable changes can still become measurable on syllable-dense tracks.
- Follow-up removed provider/AX refresh from the per-tick callback, so this
  risk is now about visual elapsed-time recomputation and timing-boundary scans,
  not provider work on every syllable tick.

Recommended next step:

- Precompute timing boundaries for each document or keep a cursor per current document.
- Profile with SwiftUI and Time Profiler before changing.
- Keep the high-frequency clock visible-only.

### PERF-RESEARCH-007: Trace and DerivedData hygiene is documented but still needs strict tooling

Evidence:

- `reports/performance-flaws.md` keeps `PERF-002` open for trace artifact bloat.
- `./script/profile.sh disk` reports trace and DerivedData sizes.
- `./script/profile.sh clean` exists, but it removes artifacts and should stay explicit.

Risk:

- Agents may run repeated profiling and leave large local artifacts.
- If cleanup is too manual, later runs become slower and harder to compare.

Recommended next step:

- Keep cleanup manual, but add a non-destructive doctor/report mode that says what would be removed.
- Add run filters by mode/scenario/validity so agents do not over-read old runs.

## Resource Work To Prioritize

1. Default launch idle decision.
2. Translation linkage decision and fresh baseline.
3. Parsing actor or nonisolated parsing helpers.
4. Release/reset path for live provider pipeline.
5. Bounded cache and negative-cache policy.
6. Strict profile report filters and live verification summaries.

## Measurement Rules To Keep

- Do not compare Debug and Release as if they are the same mode.
- Do not compare demo and live traces as regressions.
- Do not claim a live lyrics fix from build/tests alone.
- Use run IDs, usage CSVs, trace paths, and `cv.MusicFloat` logs as evidence.
- Treat `--drive-music` as mutating active Music.app playback and call that out.
