# MusicFloat Translation Architecture Plan

Reviewed: 2026-05-24 · Updated: 2026-05-25 (SDK verification pass)

This is a planning note only. It should guide later implementation, not enable real translation yet.

Deployment target: **macOS 26.5**. All Translation APIs discussed here are unconditionally available at this target. The plan documents version boundaries for reference but implementation does not need availability guards.

2026-05-25 follow-up: the Apple Translation implementation remains build-gated.
Debug can compile it through `ENABLE_APPLE_TRANSLATION`; default Release no
longer defines that flag, and fresh `otool -L` verification showed no
Translation/NaturalLanguage linkage in the default Release binary. Use
`script/profile.sh --apple-translation`, or `ENABLE_APPLE_TRANSLATION_BUILD=1`,
for explicit Translation/NaturalLanguage profiling. Keep future
memory/performance claims split between default Release and that
translation-enabled lane.

Clean snapshot startup/demo pair `20260525-082557Z-demo-Direct-Sample-8af2ba8`
vs `20260525-082703Z-demo-Direct-Sample-8af2ba8` did not reproduce a startup
RSS jump from merely linking Translation/NaturalLanguage. This does not measure
an active `TranslationSession`; repeat once real translation requests are wired.

## Goal

Build translation as a native, privacy-first provider pipeline for floating lyrics. The app should eventually translate lyrics quickly enough for an overlay, but the architecture should stay small, cancellable, measurable, and easy to route away from any provider that proves too heavy or unreliable.

## Recommendation

Use Apple's `Translation` framework as the first real provider behind the existing `TranslationProvider` boundary.

Reasons:

- It is native macOS API surface and fits the app's no-network-first posture.
- It avoids sending raw lyrics and listening context to a third-party service.
- It supports custom translation sessions, batch translation, language availability checks, and installed/supported/unsupported states.
- It can stay isolated behind `TranslationProvider`, `RuntimeFeatureFlags`, and `ProviderPipelineController`.

Keep cloud translation as a later, explicit adapter. A cloud provider should require a visible setting, network entitlement, provider attribution, privacy wording, and cache policy changes.

## Current SDK Notes

Local environment: Xcode 26.5 / macOS 26.5 SDK, deployment target 26.5. All claims verified via `swiftc -typecheck`.

### Translation API availability by OS version

| API | Minimum macOS | Available at target? |
|---|---|---|
| `import Translation` | 15.0 | ✓ |
| `TranslationSession` (base class) | 15.0 | ✓ |
| `TranslationSession(installedSource:target:)` programmatic init | **26.0** | ✓ |
| `TranslationSession.Strategy` (`.highFidelity` / `.lowLatency`) | **26.4** | ✓ |
| `LanguageAvailability` | 15.0 | ✓ |
| SwiftUI `.translationTask` modifier | 15.0 | ✓ (unused) |
| `NLLanguageRecognizer` | 10.14 | ✓ |

### Architecture consequence

Because we target 26.5, the programmatic `TranslationSession(installedSource:target:)` initializer is available. This means the translation pipeline can be **headless** — a pure async/actor pipeline with no SwiftUI view dependency. We do not need `.translationTask` or a bridge view.

**Pre-26.0 constraint (not relevant here, documented for completeness):** Before macOS 26.0, `TranslationSession` could only be obtained via SwiftUI `.translationTask`, which would force the translation pipeline through a view coordinator. Our 26.5 target sidesteps this entirely.

### Verified claims

- `import Translation` compiles against macOS 26.5 SDK. ✓
- `TranslationSession.Strategy` enum with `.highFidelity` and `.lowLatency` values compiles. ✓
- `LanguageAvailability` compiles (but `Locale.Language` identifiers use `Locale.Language(identifier:)`, not `.english`/`.french` static members). ✓

## Provider Shape

Keep the public app boundary independent of Apple-specific types.

Future request type:

- lyric document or stable lyric line IDs,
- optional source language,
- target language,
- provider preference or strategy,
- cache policy,
- optional track context only if the user has allowed it.

Future response type:

- target language,
- translated lines keyed by original `LyricLine.ID`,
- provider attribution,
- source/target language actually used,
- cache status,
- broad error/status reason.

Do not pass `TranslationSession` into SwiftUI overlay views. With our 26.5 deployment target, the programmatic `TranslationSession(installedSource:target:)` init is available — the translation pipeline can be headless async/actor code with no SwiftUI view dependency. (The older macOS 15–25 `.translationTask` path is not needed here.)

## Runtime States

Translation needs more states than the current mock result ever exposes. The current `ProviderRuntimeState` has 5 cases (`idle`, `loading`, `ready`, `unavailable`, `failed`). Translation needs ~10 states, which is a significant expansion — consider a composite design (base state plus a translation sub-state) rather than a flat enum to avoid complicating the lyrics-only path.

States needed:

- idle,
- checking language availability,
- unsupported language,
- unsupported language pair,
- needs language download,
- downloading language resources,
- translating,
- ready,
- cancelled,
- failed.

The important product rule: missing language downloads should be visible and user-controlled. MusicFloat should not surprise the user with background model/download work from a menu bar app.

## Batch Strategy

Prefer batch translation over translating the active line every time the lyric changes.

Suggested order:

1. Translate the full current lyric document if it is small.
2. For large documents, translate a verse/window around the current playback position.
3. Keep responses keyed by `LyricLine.ID` so the overlay can update cheaply as playback advances.
4. Cancel in-flight translation on track change, overlay hide, provider mode change, or target language change.

Line-by-line translation is cheaper to display but can lose idioms, repeated context, and poetic intent. Full-song translation has better context but higher latency and memory cost. A verse/window strategy may become the best default after profiling.

## Language Detection

Use explicit source language when a lyrics provider supplies one. If not, use Apple's Natural Language framework as a helper before Translation:

- `NLLanguageRecognizer` can identify the dominant language and expose candidate probabilities.
- Detection can be uncertain for short lyric lines, repeated choruses, names, slang, and mixed-language songs.
- Detect over a lyric document or verse, not a single current line, unless no other text is available.

If detection is uncertain, let the Translation framework auto-detect where possible or show a provider state that explains translation is unavailable for that pairing.

## Cache Plan

Use two tiers, measured before broadening:

- Memory cache: current track plus a few recent tracks; bounded by number of lines and total text size.
- Disk cache: later, under the user's Caches directory, because translations are recreatable.

Cache key should include:

- normalized source line text or document hash,
- source language if known,
- target language,
- provider ID,
- provider strategy,
- lyrics source ID/version when known,
- provider/model version if exposed.

Do not log or store more than the overlay needs. Avoid raw provider payload archives. Add invalidation when lyrics source, target language, provider, or strategy changes.

Current implementation status: successful `LyricTranslation` values are
`Codable` and cached in the shared media cache as JSON data. Runtime cache keys
include provider identifier, normalized target language, lyrics source, timing
shape, source language, line IDs, line text, and syllable timing, then collapse
that material into a bounded SHA-256 redacted key string. The cache key does not
grow with song length and does not expose raw lyrics.
The app now uses `DiskBackedMediaCache` so translation payloads can persist only
when the user enables the Disk cache setting. Memory entries are bounded by the
shared LRU/TTL `MediaCachePolicy` (`maxEntries`, `maxTotalCost`, and
translation TTL), while disk entries are additionally bounded by entry count,
total cost, object cost, TTL, and opt-in persisted namespaces. Disk filenames
and the index use hashed lookup keys, and Settings exposes usage plus Clear
Cache. Raw lyrics remain excluded from disk persistence until that policy is
separately approved.

## Privacy And Entitlements

Apple on-device translation does not require a network entitlement from MusicFloat.

Current entitlement state: `MusicFloat/MusicFloat.entitlements` is empty and
the app sandbox is disabled in the active project settings. LRCLIB and Apple
Music web requests work in that unsandboxed mode. If sandboxing is restored for
default/demo or distribution builds, LRCLIB, Apple Music web lookup, or any
future cloud translation provider will need a deliberate
`com.apple.security.network.client` entitlement decision. Apple on-device
Translation itself should not be used as the reason for that entitlement.

When a cloud translation provider is later added, settings and documentation
must explain to the user that lyrics may leave the device.

Telemetry must not log:

- raw lyrics,
- translated lyrics,
- full song titles or listening history,
- provider tokens,
- request payloads.

Telemetry may log:

- provider family,
- language pair,
- line count,
- character count,
- cache hit/miss counts,
- duration,
- cancellation reason,
- broad error class.

## Profiling Signals

Add signposts around:

- language availability checks,
- model/session preparation,
- translation batch requests,
- cache reads and writes,
- cancellation paths,
- overlay snapshot updates after translation.

Use Instruments templates:

- Logging: verify signposts and state transitions.
- Time Profiler: translation and parsing cost.
- Allocations: model/session/cache memory.
- Swift Concurrency: task lifetimes and cancellation.
- SwiftUI: body recomputation while active lyrics update.
- Power Profiler/System Trace: idle wakeups and hidden overlay behavior.

Expected performance principle: active lyric movement may wake at lyric boundaries, but hidden overlay work should be cancelled unless a future feature flag explicitly allows background refresh.

## Staged Roadmap

1. Refine `TranslationProvider` into request/response/status types while keeping the mock provider. Also extend `LyricsDocument` with an optional `sourceLanguage` field for language detection.
2. Add settings for translation mode and target language using stable identifiers (e.g., `Locale.Language`), replacing the current free-text `TextField` which accepts arbitrary display strings. Use a `Picker` or validated input backed by `LanguageAvailability.supportedLanguages`.
3. Add `LanguageAvailability` checking behind an Apple provider placeholder.
4. Implement an Apple installed-language provider path using `TranslationSession(installedSource:target:)` (available at our 26.5 target).
5. Add a user-controlled download-capable flow if needed.
6. Add batch translation and cancellation tests.
7. Add bounded memory cache for current/recent tracks. Follow-up status: the
   shared `EphemeralMediaCache` now has bounded in-memory policy primitives,
   and successful runtime translations are wired through it with privacy-safe
   provider/document/target cache keys. Provider strategy and future provider
   model/version fields still need to be added when those choices become real.
8. Add disk cache after profiling proves it is useful. Follow-up status: an
   opt-in disk cache now exists for artwork/translation payloads with Settings
   usage and clear controls. Keep raw lyrics off disk until the privacy policy
   and product affordance are explicit.
9. Profile with Logging, Time Profiler, Allocations, Swift Concurrency, SwiftUI, and Power/System Trace.
10. Consider cloud adapters only after the native path and cache shape are stable.

## Later Provider Options

Apple on-device provider:

- Best default for privacy and native feel.
- Limited by supported languages, installed resources, OS availability, and possible Apple Intelligence differences.

Cloud provider:

- Better language coverage or lyric nuance may be possible.
- Requires network entitlement, credentials, rate limiting, privacy UX, error handling, and cache opt-in.

Local model provider:

- Interesting experimental path for later.
- Likely heavier memory/CPU footprint than the app should pay at rest.
- Should be an opt-in adapter, not a default.

## Sources

- Apple Translation framework: https://developer.apple.com/documentation/translation/
- Apple TranslationSession: https://developer.apple.com/documentation/translation/translationsession
- Apple LanguageAvailability.Status: https://developer.apple.com/documentation/translation/languageavailability/status
- Apple Translating text within your app: https://developer.apple.com/documentation/translation/translating-text-within-your-app
- Apple Natural Language `NLLanguageRecognizer`: https://developer.apple.com/documentation/naturallanguage/nllanguagerecognizer
- Apple Foundation Models overview: https://developer.apple.com/documentation/foundationmodels/
- Apple App Sandbox network client entitlement: https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.network.client
