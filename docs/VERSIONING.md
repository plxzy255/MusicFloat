# MusicFloat Versioning Convention

## Two numbers, two purposes

| Field | Meaning | Bumped by | Example |
|-------|---------|-----------|---------|
| `CURRENT_PROJECT_VERSION` | Build number | `script/bump_build.sh` post-merge | 1 → 2 → 3… |
| `MARKETING_VERSION` | Semantic version | Explicit agent/human decision | 0.1.0, 0.2.0 |

## When to bump what

```
PR merged to main  →  bump_build.sh (auto)
                       CURRENT_PROJECT_VERSION increments

Feature batch done →  agent bumps MARKETING_VERSION
                       + creates git tag (e.g. v0.1.0)
                       + optionally creates GitHub Release

Breaking change   →  minor version bump (0.1.0 → 0.2.0)
Experimental       →  no tag, just build number
```

## git tags

Tags are created for **semantic version milestones**, not every merge:

- `v0.1.0` — first profileable architecture slice
- `v0.2.0` — real Apple Music lyrics working
- `v0.3.0` — translation provider wired

Build numbers track CI lineage but don't get tags.

## GitHub Releases

Only for tagged versions the user considers distributable/testable.
Include auto-generated release notes from merged PRs.

## Profiling convention

When comparing versions, use the same mode and scenario on both sides. `--demo`
is the cheap mock-overlay sanity check; `--live` is the meaningful Apple Music
karaoke path and requires Music.app to be actively playing.

```sh
# Cheap resource sample
./script/profile.sh sample 30s --demo --scenario overlay-karaoke

# Single Instruments template
./script/profile.sh record "Time Profiler" 20s --live --scenario apple-music-karaoke

# Compare two durable run records
./script/profile.sh compare-runs <baseline-run-id> <candidate-run-id>
```

The profiler appends compact run summaries to `reports/performance-runs.jsonl`.
Use `./script/profile.sh report` to list recent runs and include run IDs in PR
notes. Do not treat mixed-mode traces as regression evidence.
