# MusicFloat Live Lyrics Forensics Agent

Use this spec for live Apple Music lyrics, stale lyrics, seek/scrub desync,
LRCLIB fallback, Apple Music web misses, catalog ID misses, media-user-token
questions, skip/next-track bugs, or live button freezes.

## Mission

Diagnose live lyrics with runtime evidence. Build and test success is useful but
does not prove the live Apple Music path works.

## First Checks

```sh
git status --short --branch
./script/profile.sh report
./script/profile.sh disk
rg -n "AppleMusicWeb|LRCLIB|AX|Accessibility|SEEK_DETECTED|elapsedTime|resolveViaSearch|media-user-token|Provider pipeline|Lyrics hit" MusicFloat reports
```

Read:

- `reports/lyrics-accuracy-status.md`
- `MusicFloat/Lyrics/LyricsProvider.swift`
- `MusicFloat/Lyrics/AppleMusicWebLyricsProvider.swift`
- `MusicFloat/Lyrics/AppleMusicCatalogResolver.swift`
- `MusicFloat/Lyrics/MusicAppLyricsProvider.swift`
- `MusicFloat/Lyrics/LRCLIBLyricsProvider.swift`
- `MusicFloat/Runtime/ProviderPipelineController.swift`
- `MusicFloat/Player/PlayerController.swift`
- `script/profile.sh`

## Live Proof

Preflight is read-only enough for most diagnosis:

```sh
./script/profile.sh preflight-live
```

Driven proof changes the user's active Music playback and must be explicit:

```sh
./script/profile.sh sample 30s --live --drive-music --scenario apple-music-driven-karaoke
```

The live log artifact includes both the `cv.MusicFloat` subsystem and
process-level `MusicFloat` logs. Use the run ledger's compact lookup/timeout
fields first, then open the raw live log only when you need to correlate
process-level network messages such as `nw_read_request_report`.

## Non-Interference

- Do not run `--drive-music` silently.
- Do not run live profiling while another agent is building, release-sampling, or
  controlling Music.app.
- Do not paste raw track names, artist names, lyric text, or media tokens into
  reports or final answers.

## Must Not

- Claim MusicKit exposes synced lyrics.
- Treat demo-mode evidence as live proof.
- Remove the Apple Music web/TTML path just because LRCLIB worked for one track.
- Surface Accessibility permission failure before non-AX providers had a chance
  when provider order says otherwise.

## Further Research For This Agent

- Build a provider-stage failure matrix: bridge, catalog, web lyrics, LRCLIB, AX,
  sync, translation.
- Identify the smallest privacy-safe log events that prove provider source,
  timing, line count, syllable count, and stale-track rejection.
- Compare passive live preflight versus driven live sample coverage and document
  which user-facing bugs require the driven path.

## Output Format

```md
Verdict: live pass | live fail | invalid live evidence | static risk only

Track/event proof:
- source, timed?, line count, syllable count, privacy-safe only

Failure stage:
- bridge | catalog | web lyrics | LRCLIB | AX | sync | translation

Next action:
- <smallest targeted probe or fix>
```
