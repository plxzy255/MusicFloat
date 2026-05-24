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

### PERF-004: Apple Translation links translation frameworks at overlay startup

- Status: resolved in PR #13 follow-up
- First seen: PR #13 validation run
- Signal: same-mode Release `--demo` overlay samples showed higher candidate RSS
  before any settings or real translation workflow was opened.
- Affected modes: demo overlay, likely live overlay startup
- Evidence: `20260524-233022Z-demo-Direct-Sample-19fc78b` vs
  `20260524-233051Z-demo-Direct-Sample-1e7afcb` reported avg RSS
  85.7 MB -> 121.5 MB and max RSS 118.2 MB -> 148.2 MB. `otool -L`
  showed the candidate binary newly linked `Translation.framework`,
  `_Translation_SwiftUI.framework`, `NaturalLanguage.framework`, and
  `libswiftNaturalLanguage.dylib`.
- Fix: `LyricsDocument` no longer runs NaturalLanguage inference during init,
  the live provider pipeline is created only when live mode starts, and Apple
  Translation/NaturalLanguage framework usage is gated behind
  `ENABLE_APPLE_TRANSLATION` so the default `--demo` build stays mock-only.
- Validation: same-mode 30s Release `--demo --scenario overlay-karaoke`
  samples `20260524-234057Z-demo-Direct-Sample-19fc78b` vs
  `20260524-234551Z-demo-Direct-Sample-1e7afcb` reported avg RSS
  83.7 MB -> 83.4 MB and max RSS 104.9 MB -> 87.0 MB. Follow-up `otool -L`
  confirmed the fixed candidate no longer links Translation or NaturalLanguage
  frameworks in the default Release binary.
- Next check: add a dedicated live-translation build/profile path with
  `ENABLE_APPLE_TRANSLATION` and compare its cost separately from mock/demo.

### PERF-003: Deprecated karaoke Text concatenation

- Status: resolved in PR #12
- First seen: PR #9 review/build warnings
- Signal: SwiftUI warned that `Text + Text` is deprecated in macOS 26.
- Affected modes: demo, live overlay rendering
- Fix: segmented karaoke text now renders through one `AttributedString`,
  preserving wrapping and per-syllable styling without `Text` concatenation.
- Validation: `xcodebuild test -project MusicFloat.xcodeproj -scheme MusicFloat
  -destination 'platform=macOS' -derivedDataPath .codex/DerivedData`
