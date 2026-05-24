# Live Lyrics Accuracy — Status & Next Steps

Last updated: 2026-05-24

Snapshot of where the live-lyrics pipeline stands after the active-line AX pass and the Apple Music web-API integration. Tracks what works, what doesn't, and the most useful next moves.

## Current pipeline

Lyric resolution runs in this order inside `PublicLyricsProvider.lyrics(for:)`:

1. **AppleScript library lyrics** (`MusicAppLyricsProvider.fetchCurrentTrackLyrics`) — only canonical `.musicApp` results are accepted at this stage. The internal AX fallback is deliberately filtered out here so the web API gets a chance.
2. **Apple Music web API** (`AppleMusicWebLyricsProvider`) — fetches TTML from `amp-api.music.apple.com/v1/catalog/{sf}/songs/{id}` with the user's `media-user-token` and a developer JWT scraped from the web player's `index~XXXXX.js` bundle. Returns full timed multi-line `LyricsDocument` with optional per-syllable timings.
3. **LRCLIB** — timed match if available, with an AX-driven calibration pass that nudges the LRC clock when it drifts. Skipped entirely when the "Allow LRCLIB / Music app UI fallback" toggle is off.
4. **AX panel scrape** — single-line `.musicAppUI` document. Active-line detection keys off button-frame height (the active line auto-resizes ~1.33× larger), with a viewport filter and geometric centering as tiebreakers.

Missing Accessibility permission no longer blocks non-AX providers: canonical AppleScript lyrics still return immediately, then Apple Music web and LRCLIB are allowed to run before an AX-specific permission message is surfaced.

The live-refresh tick in `ProviderPipelineController` recognizes the source of the current document and will:

- Skip everything for `.appleMusicWeb` timed docs (authoritative, no AX overlay).
- Run text-match calibration for `.lrclib` timed docs (matches AX active-line text against the LRC document, nudges `offsetCorrection`, ±10s safety clamp).
- Replace `.musicAppUI` docs in place when the AX scrape returns new text.

## What works

- **Catalog songs with a configured `media-user-token`**: the TTML path lights up reliably. Logs show `Lyrics hit appleMusicWeb timed=true lines=N` and the overlay tracks Music's highlight closely on a stable playback.
- **LRCLIB calibration**: when LRCLIB returns timed lyrics for a different master than the user is playing, the AX-driven calibration nudges the clock back into agreement using the overlay's effective live elapsed time rather than the sparse now-playing snapshot.
- **Mock preview**: architecture defaults stay fully mock; the public Apple provider stack is only selected for live Apple Music mode.
- **AX active-line detection**: button-height heuristic + viewport filter avoids the prefetch-buttons-far-off-viewport trap and the wrapped-2-line-inactive-lyric trap. Works without Music exposing any state attribute (the AX dump confirmed only the standard skeleton is published).

## Known issues

- **Seek / scrub desync**: jumping forward in a track via Music's controls puts the overlay several lines behind for some songs. The TTML carries absolute times so theoretically a fresh `elapsedTime` should resync immediately. Suspected: the high-frequency local tick in `PlayerController` keeps extrapolating from the last-emitted elapsed without picking up the new value, or Music's `playerInfo` notification doesn't fire reliably on seeks (only on play/pause/track-change). Needs a probe — log `elapsedTime` jumps and timestamps to see whether we're getting the seek event at all.
- **Catalog ID resolution misses**: some tracks log `AM web: could not resolve catalog ID for track` and fall back to LRCLIB / AX. Two root causes likely:
  - AppleScript `URL of current track` is empty for some catalog playback paths (cloud library matches, Apple Music radio, queued recommendations).
  - The catalog-search fallback only requests `types=songs`; matches on duration ±1s and normalized title equality. Probably too strict for renamed/translated/explicit-tagged variants.
- **Storefront language**: the user's account is `storefront=ru lang=ru` — currently the lyrics fetch passes the storefront's `defaultLanguageTag` as the `l` parameter, which can return Russian transliteration of English lyrics when the user wants the original. Should probably default to the song's primary language or expose a setting.
- **One-line lag on some songs**: even with the TTML doc loaded, the overlay sometimes shows the line just *before* the actual highlight for a beat. Could be the TTML having silent intro padding (some Apple TTML uses `<p begin="00:00.001">` on first vocal but Music's scroll engine doesn't start moving until a few hundred ms later).

## Next steps, ranked

1. **Probe seek behavior** — add temporary `elapsedTime` jump-detection logging in `MusicAppBridge.events`. Want to see whether seeks fire notifications, what the elapsed gap looks like, and whether the local tick is replaced cleanly. Cheap and unblocking.
2. **Per-syllable rendering** — `LyricLine.syllables` is already populated by `TTMLParser` but the overlay still renders whole lines. A karaoke-style highlight would mask the one-line lag entirely (the syllable timings are absolute and don't depend on which line we're "on"). Highest visible quality lift available.
3. **Use the dedicated `/songs/{id}/syllable-lyrics?extend=ttmlLocalizations` endpoint** (per YouLyPlus' inject script). Smaller payload, returns all language variants at once, lets us pick the original-language TTML even on a non-English storefront.
4. **Improve catalog ID resolution** —
   - Loosen search picker: accept duration ±3s by default, match on normalized-title containment, prefer `attributes.hasLyrics == true` results.
   - If AppleScript URL is missing, try `cloud universal id` from AppleScript and look up `/v1/catalog/{sf}/songs?filter[equivalents]={id}`.
   - Cache resolutions per `track.id` so failed resolutions don't keep retrying every refresh.
5. **Switch the AX fallback to a "translation only" role** — once the web path is reliable, the AX scrape is purely for AppleScript-library tracks that have no catalog ID. Could degrade gracefully without showing it at all when fallback is off.

## Parked

- **MusicKit `MusicCatalogResourceRequest`** for lyrics — requires an Apple Developer team to mint a long-lived developer token. The web-player scrape pattern dodges that. Keep as a fallback path if Apple ever locks down the `index~XXX.js` token.
- **MediaRemote private framework** — gated on SIP-disabled entitlement and unlikely to carry timed-lyrics payloads. Exploration-only on the user's own machine.
- **Per-syllable karaoke overlay** — captured in the data model now; deferred until #2 above is greenlit.

## Reference repos consulted

Located in `.tmp/`, not committed:

- `Manzana-Apple-Music-Lyrics` — confirmed the developer-token scrape + endpoint shape we adopted.
- `apple-music-downloader` — confirmed `Bearer` + `media-user-token` header pattern.
- `YouLyPlus` — runs inside the Music web player so it gets the token for free; surfaced the cleaner `/songs/{id}/syllable-lyrics?extend=ttmlLocalizations` endpoint and `hasLyrics` skip heuristic.
- `LyricFever` — uses LRCLIB / NetEase / Spotify only; doesn't touch the Apple Music web API.
- `applemusic-like-lyrics` — frontend monorepo; not relevant to the auth/fetch path.
