# MusicFloat Agent Check

Use this spec when the user asks "verify", "handoff", "are we done", "before
PR", "what should Codex run", or when a broad report-backed change needs a final
completion gate.

## Mission

Confirm the current checkout has coherent source, reports, tests, app launch
proof, and profiling evidence metadata. This agent is a verifier and curator,
not a live-lyrics investigator.

## First Checks

Start with the stable handoff gate:

```sh
git status --short --branch
./script/agent_verify.sh
```

If `agent_verify.sh` fails, reduce to the smallest failing piece:

```sh
xcodebuild test -project MusicFloat.xcodeproj -scheme MusicFloat -destination 'platform=macOS' -derivedDataPath .codex/DerivedData
./script/build_and_run.sh --verify
./script/profile.sh report
./script/profile.sh disk
```

For Release linkage or identity claims, add the focused Release checks from
`release-identity-doctor.md`; do not install or replace the user's local app
unless explicitly asked.

## Non-Interference

- `agent_verify.sh` launches/stops MusicFloat through `build_and_run.sh
  --verify`; do not overlap it with profiling, release, live-lyrics, or another
  build agent.
- Do not run `--drive-music`, live driven profiling, release install, trace
  clean, broad `pkill`, or broad `killall`.
- Do not mark live lyrics, seek/scrub, or Music.app behavior fixed without a
  live workflow that explicitly changes Music playback.
- Do not paste raw lyrics, title, artist, album, or personal listening history
  into reports.

## Report Duties

Check whether the current task changed evidence for:

- `reports/bugs-and-issues.md`
- `reports/performance-flaws.md`
- `reports/lyrics-accuracy-status.md`
- `reports/report-index.md`
- the relevant `reports/research-2026-05-25-*.md` follow-up sections

Prefer appending a dated follow-up note to research reports instead of rewriting
the original research snapshot.

## Output Format

```md
Verdict: ready | not ready | blocked | live evidence still required

Verification:
- <command>: pass/fail and key evidence

Reports:
- <report updated or stale item remaining>

Residual risk:
- <only risks that matter for handoff>

Side effects:
- MusicFloat launched/stopped? yes/no
- Music.app playback changed? yes/no
```
