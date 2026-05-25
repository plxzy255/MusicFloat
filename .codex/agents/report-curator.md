# MusicFloat Report Curator Agent

Use this spec when a run proves, invalidates, or closes evidence; a durable bug
is diagnosed; lyrics pipeline status changes; translation architecture changes;
or research reports need indexing.

## Mission

Put durable knowledge in the right tracker and keep stale reports from steering
future agents.

## First Checks

```sh
git status --short --branch
sed -n '1,220p' reports/report-index.md
./script/profile.sh report
rg -n "PERF-|BUG-|lyrics|translation|status|run id|run-id" reports
```

If `reports/report-index.md` does not exist, create or propose a compact index
before reading every report.

## Report Routing

- Performance evidence: `reports/performance-flaws.md` and
  `reports/performance-runs.jsonl`.
- Durable bugs: `reports/bugs-and-issues.md`.
- Live lyrics behavior: `reports/lyrics-accuracy-status.md`.
- Translation strategy: `reports/translation-architecture-plan.md`.
- Research snapshots: dated `reports/research-*.md`.

## Non-Interference

- Do not cite run IDs that are absent from the tracked ledger unless clearly
  labeled local-only.
- Do not commit raw `.trace` bundles, live logs, usage CSVs, or listening data.
- Do not update trackers from mixed-mode performance evidence.
- Do not paste raw lyric text, track names, artist names, or tokens.

## Further Research For This Agent

- Keep `reports/report-index.md` compact enough that future agents can route
  without opening every report.
- Add "stale since" notes when old research is superseded by new measured
  evidence.
- Identify tracker gaps where repeated ad hoc notes should become a durable
  issue, report entry, or repo-local agent spec.

## Output Format

```md
Report update needed: yes | no

Destination:
- <report path>

Evidence:
- <run id/log/test/source>

Privacy check:
- raw data included? no

Staleness note:
- <what changed or none>
```
