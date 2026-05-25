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
captures MusicFloat unified logs and verifies:

- `--live` launch was requested.
- Live Apple Music bridge started.
- The initial Music.app prime is playing and has a track.
- The overlay was toggled visible.
- The overlay view appeared.
- A non-mock lyrics document was applied.
- The provider pipeline reached ready state.
- For `--drive-music` runs, a seek or track-change event was observed.
- Trace disk usage was reported.
- A per-run CPU/RSS usage CSV was captured.

If any of those checks fails, the trace fails instead of silently becoming a
demo/default-mode sample.

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
