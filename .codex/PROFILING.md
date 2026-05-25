# MusicFloat Profiling Guide

This guide documents how to collect reproducible traces without accidentally
comparing unlike runtime modes.

For Codex tasks that are specifically about benchmarking, profiling,
version-to-version comparison, memory leaks, SwiftUI invalidation, Swift
concurrency, CPU wakeups, or performance flaw hunting, also read:

```sh
.codex/agents/performance-profiler.md
```

That file is the agent contract. This file is the command guide.

## What Counts As Evidence

Use the same mode on both branches when comparing performance:

- `--demo` vs `--demo` is a mock-overlay sanity check.
- `--live` vs `--live` is the meaningful Apple Music karaoke path.
- Do not treat `v0.0.3 --demo` vs a modern `--live` trace as regression
  evidence. That compares different subsystems.

## Live Profiling Requirements

`./script/profile.sh ... --live` now refuses to proceed unless Music.app is
already running and actively playing a real track. Add `--drive-music` when the
task is about the live button, live lyrics, seek/skip handling, playback
freezes, or track-change behavior; it starts Music.app playback if needed and
performs a seek plus next-track action during the trace. During each trace it
captures MusicFloat unified logs. The live log stream includes both the
`cv.MusicFloat` subsystem and process-level `MusicFloat` lines so network-layer
messages such as `nw_read_request_report` can be correlated with provider
lookup IDs when they recur. Verification checks:

- `--live` launch was requested.
- Live Apple Music bridge started.
- The initial Music.app prime is playing and has a track.
- The overlay was shown by the menu toggle or the live auto-start path.
- The overlay view appeared.
- A non-mock lyrics document was applied.
- The provider pipeline reached ready state.
- For `--drive-music` runs, a seek or track-change event was observed.
- Trace disk usage was reported.
- A per-run CPU/RSS usage CSV was captured.

If any of those checks fails, the trace/sample fails instead of silently
becoming a demo/default-mode run.

## Commands

Preflight current Music.app playback:

```sh
./script/profile.sh preflight-live
./script/profile.sh preflight-live --drive-music
```

Record one live trace:

```sh
./script/profile.sh record "Time Profiler" 25s --live
./script/profile.sh record "Time Profiler" 30s --live --drive-music --scenario apple-music-driven-karaoke
```

Record the full live suite:

```sh
./script/profile.sh phased --live
```

Record a same-mode demo sanity check:

```sh
./script/profile.sh record "Time Profiler" 25s --demo
```

Collect direct CPU/RSS samples without Instruments:

```sh
./script/profile.sh sample 30s --demo
./script/profile.sh sample 30s --live
./script/profile.sh sample 30s --live --drive-music --scenario apple-music-driven-karaoke
```

Measure the explicit Apple Translation/NaturalLanguage lane separately from
the default Release baseline:

```sh
./script/profile.sh sample 30s --demo --apple-translation --scenario translation-enabled-overlay
./script/profile.sh record "Allocations" 30s --demo --apple-translation --scenario translation-enabled-overlay
```

The run ledger records this as `app.apple_translation_build=true`; strict
comparison rejects mixed default-vs-translation builds.

Create a clean temporary snapshot when the main checkout is dirty but the
current state needs profiling evidence:

```sh
script/profile_snapshot.sh -- ./script/profile.sh sample 30s --demo --scenario overlay-karaoke
script/profile_snapshot.sh --run -- ./script/profile.sh sample 30s --demo --apple-translation --scenario translation-enabled-overlay
script/profile_snapshot.sh --ref main -- ./script/profile.sh sample 30s --demo --scenario overlay-karaoke
```

The snapshot helper does not commit or clean the main checkout. It creates a
temporary detached worktree under `/private/tmp`, copies the current tracked and
untracked non-ignored files into a temporary commit, and points
`RUN_LEDGER`, `TRACE_DIR`, and `DERIVED_DATA_DIR` at isolated paths outside the
snapshot worktree. Use `--run` only when you intentionally want it to build,
launch, or profile the app.

Collect stripped self-release memory when the question is "what does the app in
/Applications or dist use?":

```sh
script/release_self.sh --memory --demo --memory-duration 30
script/release_self.sh --memory --live --drive-music --memory-duration 30
```

Use this path to separate installed/release RSS from Xcode Debug, DerivedData,
or Instruments-launched processes. It reports RSS samples plus `vmmap` physical
footprint; prefer physical footprint when deciding whether a high RSS number is
mostly shared framework mappings.

List recent run ledger entries:

```sh
./script/profile.sh report
```

Compare two ledger entries:

```sh
./script/profile.sh compare-runs <baseline-run-id> <candidate-run-id>
```

Inspect local artifact usage:

```sh
./script/profile.sh disk
```

Clean generated traces, local DerivedData, and raw coverage profiles:

```sh
./script/profile.sh clean
```

## Comparing PRs

For a live karaoke comparison:

1. Open Music.app.
2. Start a lyric-capable Apple Music track.
3. Use `--drive-music` unless the comparison intentionally needs passive
   playback; this exercises the "Listen to Apple Music" path plus seek/skip.
4. Run the same `script/profile.sh ... --live` command on `main`.
5. Run the same command on the PR branch.
6. Compare traces only if both runs passed live verification.

Live verification logs are written under:

```sh
.codex/traces/live-logs/
```

Per-run usage samples are written under:

```sh
.codex/traces/usage/
```

Each CSV records timestamp, process ID, RSS in KB, and CPU percentage while the
trace is running. The script prints sample count plus average/max RSS and CPU
after every trace, which makes future branch comparisons easier to sanity-check
before opening Instruments.

Live ledger rows also include compact `live_verification` fields for
privacy-safe lookup counts, timeout counts, sampled `lookup=` IDs tied to
timeouts, translation readiness, and translation cache hits. Use those summaries
before opening raw live logs.

Use `sample` when you only need resource numbers and do not need an Instruments
bundle. Use `record` or `phased` when you need Instruments timelines.

Durable run summaries are appended to:

```sh
reports/performance-runs.jsonl
```

That ledger is the small, reviewable record agents should use to answer which
branch, PR, tag, version, mode, and scenario produced a measurement. Commit
meaningful ledger entries and comparison notes; do not commit raw trace bundles.

The verification checks only require coarse state such as provider source, line
count, syllable count, and readiness. The captured unified log stream can still
include limited lyric snippets from other diagnostic log points, so treat raw
live logs as sensitive local artifacts and do not commit them.

## Agent Checklist

1. Use the same mode and scenario on baseline and candidate branches.
2. Reject mixed `--demo` vs `--live` evidence for regression calls.
3. Run `./script/profile.sh report` before and after collecting new evidence.
4. Include run IDs in PR comments or issue notes.
5. Update `reports/performance-flaws.md` when a run proves a new flaw or closes
   an existing one.
6. Run `./script/profile.sh disk` and clean raw artifacts when done.
