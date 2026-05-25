#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PROJECT="MusicFloat.xcodeproj"
SCHEME="MusicFloat"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-$ROOT_DIR/.codex/DerivedData}"
TRACE_DIR="${TRACE_DIR:-$ROOT_DIR/.codex/traces}"
RUN_LEDGER="${RUN_LEDGER:-$ROOT_DIR/reports/performance-runs.jsonl}"

print_workflow_compliance() {
  echo "== Workflow Compliance =="
  echo "Lead ownership: one lead should own this working tree, final answer, and verdict."
  echo "Shared artifacts: checkout=$ROOT_DIR"
  echo "Shared artifacts: derived_data=$DERIVED_DATA_DIR"
  echo "Shared artifacts: trace_dir=$TRACE_DIR"
  echo "Shared artifacts: run_ledger=$RUN_LEDGER"

  local overlap_pattern="xcodebuild|xctrace|Instruments\\.app|script/(build_and_run|profile|release_self)\\.sh|MusicFloat\\.app/Contents/MacOS/MusicFloat"
  local overlap_output
  local overlap_status
  set +e
  overlap_output="$(/usr/bin/pgrep -fl "$overlap_pattern" 2>/dev/null)"
  overlap_status="$?"
  set -e
  if [[ "$overlap_status" == "0" && -n "$overlap_output" ]]; then
    echo "Potential overlapping build/test/profile/release/app owners before verify:"
    echo "$overlap_output"
  elif [[ "$overlap_status" == "1" ]]; then
    echo "No obvious overlapping build/test/profile/release/app owners detected before verify."
  else
    echo "Process overlap scan unavailable or unsupported in this runtime; check manually before running shared-artifact commands."
  fi

  echo "Reminder: performance/regression comparisons require same mode/lane plus run IDs, traces, or logs."
  echo "Reminder: forbidden commands need supported approval or explicit user instruction in prompt history."
  echo "Reminder: if delegation happened, include a routing record in handoff or report notes."
}

echo "== git =="
/usr/bin/git status --short --branch
/usr/bin/git rev-parse --short HEAD

print_workflow_compliance

echo "== script syntax =="
/bin/bash -n script/agent_verify.sh
/bin/bash -n script/profile.sh
/bin/bash -n script/profile_snapshot.sh
/bin/bash -n script/generate_codex_environment.sh
/bin/bash -n script/release_self.sh

echo "== tests =="
test_log="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/musicfloat-agent-verify-test.XXXXXX")"
set +e
/usr/bin/xcodebuild \
  test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  2>&1 | /usr/bin/tee "$test_log"
test_status="${PIPESTATUS[0]}"
set -e
if [[ "$test_status" -ne 0 ]]; then
  echo "xcodebuild test failed; log: $test_log" >&2
  exit "$test_status"
fi

warning_log="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/musicfloat-agent-verify-warnings.XXXXXX")"
/usr/bin/grep -E "warning:" "$test_log" \
  | /usr/bin/grep -v "Metadata extraction skipped" \
  | /usr/bin/grep -v "XCUIAutomation.framework.*Failed to parse executable" \
  >"$warning_log" || true
warning_count="$(/usr/bin/wc -l <"$warning_log" | /usr/bin/tr -d ' ')"
if [[ "$warning_count" != "0" ]]; then
  echo "unexpected compiler warnings ($warning_count):" >&2
  /bin/cat "$warning_log" >&2
  echo "full log: $test_log" >&2
  exit 1
fi

echo "== app verify =="
./script/build_and_run.sh --verify

echo "== profile evidence =="
./script/profile.sh report
./script/profile.sh disk

echo "agent_verify complete"
