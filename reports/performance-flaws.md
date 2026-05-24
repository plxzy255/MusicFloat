# MusicFloat Performance Flaws

Use this report to connect profiling evidence to PRs, commits, tags, and fixes.
Keep raw traces out of git; cite run IDs from `reports/performance-runs.jsonl`.

## Open

### PERF-001: Invalid live benchmark evidence

- Status: open
- First seen: PR #11 setup review
- Signal: a benchmark can claim to be live without proving Music.app playback,
  overlay appearance, non-mock lyrics, and provider readiness.
- Affected modes: live profiling
- Evidence: earlier subagent demo-mode benchmark was useful as a sanity check
  but not valid Apple Music live evidence.
- Current mitigation: `script/profile.sh ... --live` preflight and live-log
  verification, plus run ledger metadata.
- Next check: collect a real `--live` baseline/candidate pair while Music.app is
  playing a lyric-capable track.

### PERF-002: Raw Instruments artifacts can bloat disk usage

- Status: monitoring
- First seen: PR #9 profiling notes
- Signal: phased Instruments traces can create multi-GB `.codex/traces` and
  DerivedData artifacts.
- Affected modes: record, phased
- Current mitigation: `script/profile.sh disk`, `script/profile.sh clean`, and
  trace-size reporting in run entries.
- Next check: confirm trace sizes stay bounded after a full live phased run.

## Resolved

### PERF-003: Deprecated karaoke Text concatenation

- Status: resolved in PR #12
- First seen: PR #9 review/build warnings
- Signal: SwiftUI warned that `Text + Text` is deprecated in macOS 26.
- Affected modes: demo, live overlay rendering
- Fix: segmented karaoke text now renders through one `AttributedString`,
  preserving wrapping and per-syllable styling without `Text` concatenation.
- Validation: `xcodebuild test -project MusicFloat.xcodeproj -scheme MusicFloat
  -destination 'platform=macOS' -derivedDataPath .codex/DerivedData`
