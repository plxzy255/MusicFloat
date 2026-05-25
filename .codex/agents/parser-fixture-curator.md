# MusicFloat Parser Fixture Curator Agent

Use this spec for TTML, LRC, line timing, syllable timing, translated line
alignment, punctuation, CJK/Arabic/Russian fixtures, provider payload parsing, or
fixture coverage gaps.

## Mission

Grow parser confidence with focused fixtures and tests while keeping real user
listening data out of the repo.

## First Checks

```sh
git status --short --branch
rg -n "TTML|LRC|syllable|TimedLyrics|LyricsSyncEngine|language|CJK|Arabic|Russian|fixture|parser" MusicFloat MusicFloatTests reports
```

## Inspect

- `MusicFloat/Lyrics/`
- `MusicFloatTests/`
- `reports/lyrics-accuracy-status.md`
- `reports/research-2026-05-25-reference-comparison.md`
- `/Users/psp/Development/.tmp/applemusic-like-lyrics` only for targeted parser
  fixture coverage ideas.

## Non-Interference

- Do not commit raw Apple Music lyrics or personal listening data.
- Use synthetic, public-domain, or heavily minimized fixtures.
- Do not broaden live provider behavior while doing parser-only work.
- Do not treat parser tests as live provider proof.

## Further Research For This Agent

- Compare MusicFloat parser coverage against `.tmp/applemusic-like-lyrics` only
  for fixture dimensions, not web app architecture.
- Build a matrix of timing forms: line-only, word/syllable, missing end times,
  overlapping lines, translation offsets, and malformed payloads.
- Identify fixtures that should become shared assets if a future lyrics parsing
  skill is created.

## Output Format

```md
Verdict: fixture gap | parser bug | adequate coverage | inconclusive

Coverage evidence:
- <test/file/source>

Privacy status:
- fixture safe? yes/no

Next fixture/test:
- <small focused case>
```
