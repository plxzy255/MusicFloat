# MusicFloat Agent Backlog - 2026-05-25

## Summary

The next Codex improvement should be a set of small repo-local agents under `.codex/agents/`. Each should own a specific MusicFloat risk zone and point to exact evidence commands, source/report files, side-effect boundaries, and report update destinations.

This backlog combines the second-pass subagent findings and local Codex-surface research.

## 2026-05-25 Follow-up Implementation Status

Implemented from this backlog:

- The repo-local agent specs now exist under `.codex/agents/`.
- `AGENTS.md` now routes future agents to the matching spec on demand instead of
  asking them to bulk-read reports.
- `script/agent_verify.sh` now gives the `musicfloat-agent-check.md` lane a real
  command.
- `script/profile.sh doctor` now gives the `codex-xcode-doctor.md` and
  `release-identity-doctor.md` specs a read-only local preflight command.
- `reports/report-index.md` now provides report routing for the agent outputs.

Still future:

- Codex environment actions for Verify/Test/Profile/Release/Doctor.
- Promotion of any MusicFloat-specific spec into a global skill/plugin. None is
  stable enough for that yet.

## Existing Agent To Keep

### `performance-profiler.md`

Status: keep as canonical.

Already covers:

- benchmark comparison,
- profiling,
- memory leaks,
- SwiftUI invalidation,
- Swift concurrency issues,
- CPU wakeups,
- startup cost,
- version-to-version flaws,
- same-mode evidence rules,
- run ID/report requirements.

Recommended follow-up:

- Add references to the new agent set once created.
- Keep performance-flaw updates under this agent or `report-curator.md`.
- Do not expand it into privacy/security/live-lyrics correctness; route those to narrower agents.

## Proposed P0 Agents

### `privacy-entitlements-reviewer.md`

Use when:

- User mentions privacy audit, telemetry safety, logs safe to share, sandbox, entitlements, Apple Events, Accessibility prompt, media-user-token, or token storage.

Mission:

- Prove whether MusicFloat logs, permissions, entitlements, and usage strings match product privacy boundaries.

First commands:

```sh
git status --short --branch
rg -n "privacy: \\.public|rawSummary|title=|artist=|album=|lyrics|media-user-token|AXTrustedCheckOptionPrompt|NSAppleEventsUsageDescription|ENABLE_APP_SANDBOX|CODE_SIGN_ENTITLEMENTS|com.apple.security" MusicFloat MusicFloat.xcodeproj reports
script/release_self.sh --status
```

Artifact commands when an app bundle exists:

```sh
codesign -dvv --entitlements :- <app-path>
plutil -p <app-path>/Contents/Info.plist
```

Inspect:

- `MusicFloat/Diagnostics/AppTelemetry.swift`
- `MusicFloat/Player/AppleMusicEventListener.swift`
- `MusicFloat/Player/MusicAppBridge.swift`
- `MusicFloat/Lyrics/LRCLIBLyricsProvider.swift`
- `MusicFloat/Lyrics/AppleMusicCatalogResolver.swift`
- `MusicFloat/Runtime/ProviderPipelineController.swift`
- `MusicFloat/MusicFloat.entitlements`
- `MusicFloat.xcodeproj/project.pbxproj`
- `AGENTS.md`

Must not:

- Paste raw lyrics, track names, artist names, albums, tokens, or listening history into reports.
- Broaden entitlements without a specific product/distribution decision.
- Prompt Accessibility permission during a read-only audit.
- Flip sandbox policy without user approval.

Update:

- `reports/bugs-and-issues.md` for runtime symptoms.
- `reports/research-2026-05-25-bug-risk-register.md` or future risk register for risk status.
- Future `reports/report-index.md` for tracker routing.

Output:

```md
Verdict: pass | fail | partial

Privacy findings:
- <file:line> <public/private payload issue>

Entitlement findings:
- sandbox/hardened runtime/status

Required product decision:
- <if any>

Safe next fix:
- <smallest change>
```

### `translation-memory-gatekeeper.md`

Use when:

- User mentions Translation framework, NaturalLanguage linkage, `ENABLE_APPLE_TRANSLATION`, translation memory, language downloads, hidden memory, translation cache, source language inference, or translation startup cost.

Mission:

- Keep Translation as a first-class feature without silently harming startup/idle memory or privacy.

First commands:

```sh
git status --short --branch
rg -n "ENABLE_APPLE_TRANSLATION|import Translation|import NaturalLanguage|translationTask|AppleTranslationProvider|TranslationSession|NLLanguageRecognizer|reduceHiddenMemoryUsage|LiveProviderPipelineControllerStore|memoryCache" MusicFloat MusicFloat.xcodeproj reports
./script/profile.sh report
```

Artifact command when Release binary exists:

```sh
otool -L <Release-binary> | rg "Translation|NaturalLanguage|_Translation"
```

Inspect:

- `MusicFloat/Translation/TranslationProvider.swift`
- `MusicFloat/Overlay/LyricsOverlayView.swift`
- `MusicFloat/Settings/SettingsView.swift`
- `MusicFloat/Runtime/RuntimeAdapterFactory.swift`
- `MusicFloat/Runtime/ProviderPipelineController.swift`
- `MusicFloat.xcodeproj/project.pbxproj`
- `reports/performance-flaws.md`
- `reports/translation-architecture-plan.md`

Must not:

- Make Translation default-on without a fresh Release baseline.
- Treat SwiftUI `.translationTask` as the final headless provider architecture without a plan.
- Trigger background language downloads invisibly.
- Log raw source lyrics or translations.
- Compare Debug and Release memory as if equivalent.

Update:

- `reports/translation-architecture-plan.md`
- `reports/performance-flaws.md`
- `reports/research-2026-05-25-resource-usage.md` or successor resource tracker.

Output:

```md
Verdict: gated | default-linked | inconclusive

Release linkage:
- <framework evidence>

Memory evidence:
- <run id or missing baseline>

Risk:
- <startup/hidden/language download/privacy>

Next measurement or fix:
- <small reversible step>
```

### `live-lyrics-forensics.md`

Use when:

- User mentions live lyrics wrong, lyrics stale, seek/scrub desync, Apple Music web miss, LRCLIB fallback, AX calibration, catalog ID miss, media-user-token, skip/next track, or live button freeze.

Mission:

- Diagnose real live Apple Music lyrics behavior with runtime evidence, not build/test-only proof.

First commands:

```sh
git status --short --branch
./script/profile.sh report
./script/profile.sh disk
rg -n "AppleMusicWeb|LRCLIB|AX|Accessibility|SEEK_DETECTED|elapsedTime|resolveViaSearch|media-user-token|Provider pipeline|Lyrics hit" MusicFloat reports
```

Live preflight:

```sh
./script/profile.sh preflight-live
```

Driven live proof only with explicit user permission:

```sh
./script/profile.sh sample 30s --live --drive-music --scenario apple-music-driven-karaoke
```

Inspect:

- `reports/lyrics-accuracy-status.md`
- `MusicFloat/Lyrics/LyricsProvider.swift`
- `MusicFloat/Lyrics/AppleMusicWebLyricsProvider.swift`
- `MusicFloat/Lyrics/AppleMusicCatalogResolver.swift`
- `MusicFloat/Lyrics/MusicAppLyricsProvider.swift`
- `MusicFloat/Lyrics/LRCLIBLyricsProvider.swift`
- `MusicFloat/Runtime/ProviderPipelineController.swift`
- `MusicFloat/Player/PlayerController.swift`
- `script/profile.sh`
- targeted tests in `MusicFloatTests/`

Must not:

- Treat build/tests as live proof.
- Run `--drive-music` silently.
- Claim MusicKit exposes synced lyrics.
- Paste raw live logs with track names or lyric text.
- Remove Apple Music web/TTML path just because LRCLIB works for a sample track.
- Surface Accessibility permission failure before non-AX providers had a chance when provider order says otherwise.

Update:

- `reports/lyrics-accuracy-status.md`
- `reports/bugs-and-issues.md`
- `reports/performance-flaws.md` only for measured live performance/evidence validity issues.

Output:

```md
Verdict: live pass | live fail | invalid live evidence | static risk only

Track/event proof:
- provider source, timed?, line count, syllable count

Failure stage:
- bridge | catalog | web lyrics | LRCLIB | AX | sync | translation

Privacy note:
- raw logs handled? yes/no

Next action:
- <smallest targeted probe/fix>
```

## Proposed P1 Agents

### `native-panel-auditor.md`

Use when:

- User mentions native UI audit, overlay smoothness, panel placement, panel width, multi-display behavior, menu bar polish, drag/focus behavior, or accessibility labels.

Mission:

- Keep the overlay and menu bar surface native, calm, and AppKit/SwiftUI ownership-correct.

First commands:

```sh
git status --short --branch
rg -n "NSPanel|NSStatusItem|FloatingPanelController|overlayWidthPreset|isMovableByWindowBackground|SettingsWindowController|MenuBarStatusItemController|MenuBarView|accessibilityLabel|help\\(" MusicFloat reports
```

Optional verification when UI behavior is in scope:

```sh
./script/build_and_run.sh --verify
./script/profile.sh record "Animation Hitches" 20s --demo --scenario overlay-karaoke
```

Inspect:

- `MusicFloat/Overlay/FloatingPanelController.swift`
- `MusicFloat/Overlay/LyricsOverlayView.swift`
- `MusicFloat/Settings/SettingsView.swift`
- `MusicFloat/MenuBar/MenuBarStatusItemController.swift`
- `MusicFloat/MenuBar/MenuBarView.swift`
- `reports/research-2026-05-25-native-smoothness.md`
- PlayStatus placement/clamping references when needed.

Must not:

- Move `NSPanel` ownership into SwiftUI views.
- Add web-style surfaces.
- Hardcode single-display placement.
- Treat unused `MenuBarView` as active without confirming live path.
- Optimize visual animation without profiling or visible proof.

Update:

- `reports/research-2026-05-25-native-smoothness.md` or successor tracker.
- `reports/bugs-and-issues.md` for durable user-visible bugs.

### `release-identity-doctor.md`

Use when:

- User asks which app is running, Release vs Debug, self install, version mismatch, LSUIElement, signing identity, installed app memory, or notarization/distribution-readiness basics.

Mission:

- Distinguish Debug, DerivedData, `dist/`, and installed bundles before making release, memory, signing, or permission claims.

First commands:

```sh
git status --short --branch
script/version.sh show
script/version.sh installed
script/version.sh running
script/release_self.sh --status
pgrep -fl MusicFloat
```

Artifact commands when bundle path is known:

```sh
plutil -extract LSUIElement raw <app-path>/Contents/Info.plist
codesign -dvv --entitlements :- <app-path>
otool -L <app-path>/Contents/MacOS/MusicFloat
```

Inspect:

- `script/release_self.sh`
- `script/version.sh`
- `docs/VERSIONING.md`
- `MusicFloat.xcodeproj/project.pbxproj`
- `MusicFloat/MusicFloat.entitlements`

Must not:

- Install or replace `/Applications/MusicFloat.app` unless user asks.
- Run memory sampling unless user asks for measurement.
- Open the app unexpectedly when the task is identity-only.
- Compare Debug and Release metrics as if equivalent.

Update:

- `reports/performance-runs.jsonl` for new measured runs.
- `reports/performance-flaws.md` for release-only flaws.
- Future report index for release/status tracker routing.

### `provider-cache-boundary-auditor.md`

Use when:

- User mentions cache, negative cache, catalog miss, provider retry, network timeout, inflight de-dupe, memory cache, disk cache, or cache clear/status.

Mission:

- Keep provider/cache behavior bounded, privacy-safe, cancellable, and measured.

First commands:

```sh
git status --short --branch
rg -n "MediaCache|memoryCache|URLSession|timeoutInterval|resolveViaSearch|LRCLIB|AppleMusicCatalogResolver|Operation timed out|inflight|cache" MusicFloat reports
./script/profile.sh report
```

Inspect:

- `MusicFloat/Cache/MediaCache.swift`
- `MusicFloat/Lyrics/LyricsProvider.swift`
- `MusicFloat/Lyrics/AppleMusicCatalogResolver.swift`
- `MusicFloat/Lyrics/LRCLIBLyricsProvider.swift`
- `MusicFloat/Lyrics/AppleMusicWebLyricsProvider.swift`
- `reports/bugs-and-issues.md`
- `reports/research-2026-05-25-reference-comparison.md`
- PlayStatus cache references.

Must not:

- Add disk cache by default.
- Store raw provider payloads or raw lyrics.
- Ignore cancellation/stale-track guards.
- Hide provider failures behind generic unavailable states without stage evidence.

Update:

- `reports/bugs-and-issues.md`
- `reports/lyrics-accuracy-status.md`
- `reports/research-2026-05-25-resource-usage.md` or successor resource tracker.

### `build-test-triage.md`

Use when:

- Compiler errors, test failures, Xcode warnings, strict concurrency warnings, strict memory-safety warnings, or CI/build failures appear.

Mission:

- Classify failures by smallest failing scope and avoid confusing stale Xcode navigator issues with current build output.

First commands:

```sh
git status --short --branch
./script/build_and_run.sh --verify
xcodebuild test -project MusicFloat.xcodeproj -scheme MusicFloat -destination 'platform=macOS' -derivedDataPath .codex/DerivedData
```

Xcode MCP:

- `XcodeListWindows`
- `BuildProject`
- `RunAllTests`
- `GetBuildLog`
- `XcodeListNavigatorIssues`

Inspect:

- failing source/test files,
- `script/build_and_run.sh`,
- `.codex/agents/performance-profiler.md` fast gate,
- Build macOS Apps `test-triage` skill guidance when needed.

Must not:

- Treat stale navigator warnings as current build failures without current log proof.
- Rewrite architecture to fix a narrow compiler/test failure.
- Ignore dirty worktree state.

Update:

- `reports/bugs-and-issues.md` if a durable bug is found.
- `reports/performance-flaws.md` only if a build/test issue affects measured performance evidence.

### `report-curator.md`

Use when:

- A run proves, invalidates, or closes evidence; a bug is diagnosed; lyrics pipeline changes; translation plan changes; or research reports need indexing.

Mission:

- Put durable knowledge in the correct report and prevent stale trackers.

First commands:

```sh
git status --short --branch
./script/profile.sh report
rg -n "<run-id>|PERF-|BUG-|lyrics|translation|status" reports
```

Inspect:

- `reports/performance-flaws.md`
- `reports/bugs-and-issues.md`
- `reports/lyrics-accuracy-status.md`
- `reports/translation-architecture-plan.md`
- `reports/performance-runs.jsonl`
- research reports

Must not:

- Cite run IDs that do not exist in the tracked ledger unless clearly labeled local-only.
- Commit raw traces/logs.
- Paste raw listening data.
- Update a tracker from mixed-mode or invalid evidence.

Output:

```md
Report update needed: yes/no

Destination:
- <report path>

Evidence:
- <run id/log/test/source>

Privacy check:
- raw data included? no
```

## Proposed P2 Agents

### `codex-xcode-doctor.md`

Use when:

- Xcode MCP missing, `xctrace` fails, Codex action confusion, active Xcode tab problems, profile scripts fail for environment reasons, or the agent is unsure whether to use Xcode MCP vs shell.

Mission:

- Diagnose local Codex/Xcode/MCP affordances read-only and choose the right tool path.

First commands:

```sh
git status --short --branch
xcrun --find mcpbridge
./script/profile.sh disk
```

Tool checks:

- Xcode MCP `XcodeListWindows`.
- Xcode MCP `XcodeListNavigatorIssues`.
- Xcode MCP `GetTestList` if available.
- `codex mcp list --json` if safe/available.

Must not:

- Treat sandbox/cache permission failure as project code failure.
- Request broad approvals without explaining the exact profiling/tool need.
- Run `--drive-music`, install release builds, or clean traces as part of a read-only doctor.

Global promotion:

- Good candidate for future global skill after it works in MusicFloat plus another macOS repo.

### `parser-fixture-curator.md`

Use when:

- TTML/LRC parser, localization, romanization, ruby, duet, spacing, timestamp normalization, malformed docs, fixtures, or round-trip parser stability comes up.

Mission:

- Turn parser behavior into privacy-safe MusicFloat-owned fixtures and tests without copying third-party fixture data.

First commands:

```sh
git status --short --branch
sed -n '1,260p' MusicFloatTests/TTMLParserTests.swift
find .tmp/applemusic-like-lyrics -path '*/node_modules' -prune -o -type f \\( -path '*/tests/*' -o -name '*fixture*' \\) -print | sort
```

Reference dimensions to study, not copy:

- external TTML fixtures,
- sidecar/localization metadata,
- romanization/transliteration,
- ruby annotations,
- background wrappers,
- LRC timestamp normalization,
- CRLF handling,
- invalid timestamp handling,
- parse/stringify stability.

Must not:

- Copy third-party fixture text directly into MusicFloat.
- Store real user lyrics/listening history as test fixtures.
- Expand parser scope without updating provider/rendering expectations.

Update:

- `reports/lyrics-accuracy-status.md`
- future parser fixture report or test plan.

### `musicfloat-agent-check.md`

Use when:

- User asks "verify", "handoff", "are we done", "before PR", "what should Codex run", or after normal code changes.

Mission:

- Be the simple completion gate agent that checks repo state, build/test status, app verify status, and report obligations.

First commands:

```sh
git status --short --branch
./script/build_and_run.sh --verify
xcodebuild test -project MusicFloat.xcodeproj -scheme MusicFloat -destination 'platform=macOS' -derivedDataPath .codex/DerivedData
./script/profile.sh report
./script/profile.sh disk
```

Must not:

- Run live driven profiling unless the user asked.
- Install release builds.
- Clean traces.
- Mark live lyrics fixed without live evidence.

Output:

```md
Verdict: ready | not ready | partial

Gates:
- build/app verify:
- tests:
- profile report reviewed:
- report updates needed:
- live proof needed? yes/no
```

## Backlog Priority

First wave:

1. `privacy-entitlements-reviewer.md`
2. `live-lyrics-forensics.md`
3. `translation-memory-gatekeeper.md`
4. `release-identity-doctor.md`
5. `report-curator.md`

Second wave:

1. `native-panel-auditor.md`
2. `provider-cache-boundary-auditor.md`
3. `build-test-triage.md`
4. `codex-xcode-doctor.md`

Third wave:

1. `parser-fixture-curator.md`
2. `musicfloat-agent-check.md`

Rationale:

- First wave protects privacy, live correctness, memory baseline, release identity, and report truth.
- Second wave improves routine development quality.
- Third wave strengthens tests and handoff consistency once the core risk agents exist.
