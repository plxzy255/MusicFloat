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

When comparing versions, profile with `--demo` to exercise real hot paths:

```sh
# Single template
./script/profile.sh record "Time Profiler" 20s --demo

# Full phased suite (9 templates)
./script/profile.sh phased --demo

# Compare two version traces
./script/profile.sh compare traces/0.1.0-Time-Profiler.trace traces/0.2.0-Time-Profiler.trace
```

The `--demo` flag auto-shows the floating overlay with mock playback,
mock lyrics, and mock translation — exercising the sync engine, SwiftUI
views, provider pipeline, and panel management without manual interaction.
