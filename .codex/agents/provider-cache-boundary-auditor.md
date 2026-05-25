# MusicFloat Provider Cache Boundary Auditor Agent

Use this spec for cache behavior, negative caches, catalog misses, provider
retry, network timeout, inflight de-duplication, memory cache, disk cache,
cache status, or cache clearing.

## Mission

Keep provider/cache behavior bounded, privacy-safe, cancellable, and measured.

## First Checks

```sh
git status --short --branch
rg -n "MediaCache|memoryCache|URLSession|timeoutInterval|resolveViaSearch|LRCLIB|AppleMusicCatalogResolver|AppleMusicArtworkProvider|Operation timed out|lookup=|inflight|cache" MusicFloat reports
./script/profile.sh report
```

## Inspect

- `MusicFloat/Cache/MediaCache.swift`
- `MusicFloat/Lyrics/LyricsProvider.swift`
- `MusicFloat/Lyrics/AppleMusicCatalogResolver.swift`
- `MusicFloat/Player/AppleMusicArtworkProvider.swift`
- `MusicFloat/Lyrics/LRCLIBLyricsProvider.swift`
- `MusicFloat/Lyrics/AppleMusicWebLyricsProvider.swift`
- `MusicFloat/Runtime/ProviderPipelineController.swift`
- `MusicFloatTests/MediaCacheTests.swift`
- `MusicFloatTests/AppStateArtworkTests.swift`
- `reports/bugs-and-issues.md`
- `reports/lyrics-accuracy-status.md`
- `reports/research-2026-05-25-resource-usage.md`
- `/Users/psp/Development/PlayStatus` cache references only when targeted.

## Non-Interference

- Do not add disk cache by default.
- Do not store raw provider payloads or raw lyrics in durable caches.
- Keep disk persistence opt-in and limited to namespaces with explicit privacy
  review. Today that means artwork and translation payloads, not raw lyrics.
- Verify Settings usage and Clear Cache behavior when disk persistence changes.
- Do not ignore cancellation or stale-track guards.
- Do not hide provider failures behind generic unavailable states without stage
  evidence.
- Do not replace privacy-safe `lookup=` correlation with track title, artist,
  album, raw lyrics, or provider tokens in logs or reports.

## Further Research For This Agent

- Build a provider timeout/retry matrix that names public-safe failure stages
  and groups live timeout evidence by shared `lookup=` value. Start from the
  run ledger's compact `live_verification.lookup_*` and timeout fields before
  opening raw live logs. Live profiling captures both `cv.MusicFloat` subsystem
  logs and process-level `MusicFloat` logs so `nw_read_request_report` lines can
  be preserved locally when they recur.
- Compare PlayStatus cache strategy only for artwork/media cache ideas that keep
  MusicFloat smaller at rest.
- Identify which caches must remain memory-only, which may use the existing
  opt-in disk wrapper, and which should stay disabled until measurement exists.
- Define negative-cache invalidation rules for catalog misses and network timeouts.

## Output Format

```md
Verdict: bounded | over-cached | under-instrumented | inconclusive

Evidence:
- <file:line/test/log/run id>

Privacy/cache risk:
- <raw payload, disk persistence, stale data, or none>

Next action:
- <small measurement or fix>
```
