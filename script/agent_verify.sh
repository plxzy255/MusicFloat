#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PROJECT="MusicFloat.xcodeproj"
SCHEME="MusicFloat"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-$ROOT_DIR/.codex/DerivedData}"

echo "== git =="
/usr/bin/git status --short --branch
/usr/bin/git rev-parse --short HEAD

echo "== script syntax =="
/bin/bash -n script/profile.sh
/bin/bash -n script/profile_snapshot.sh
/bin/bash -n script/generate_codex_environment.sh

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
