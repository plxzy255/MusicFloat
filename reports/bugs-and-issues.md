# MusicFloat Bugs And Issues

Use this report for runtime bugs, rough edges, and investigation notes that should
survive across agents. Keep entries short, include the exact symptom, and update
the status as fixes land or evidence changes.

## Open

### Network read timeout during provider work

- Status: open
- First noted: 2026-05-24
- Symptom: `nw_read_request_report [C1] Receive failed with error "Operation timed out"`
- Area: Apple Music web lyrics / network provider runtime
- Impact: unknown; this may be a transient network-layer timeout unless it
  correlates with failed lyric fetches or user-visible unavailable states.
- Next check: capture surrounding `cv.MusicFloat` provider logs and the active
  endpoint/result when this appears.

## Resolved

- None yet.
