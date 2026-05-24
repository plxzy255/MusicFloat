#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MusicFloat"
PROJECT="MusicFloat.xcodeproj"
SCHEME="MusicFloat"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-$PWD/.codex/DerivedData}"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_EXEC="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
TRACE_DIR="${TRACE_DIR:-$PWD/.codex/traces}"
LIVE_LOG_DIR="${LIVE_LOG_DIR:-$TRACE_DIR/live-logs}"
USAGE_LOG_DIR="${USAGE_LOG_DIR:-$TRACE_DIR/usage}"
USAGE_SAMPLE_INTERVAL="${USAGE_SAMPLE_INTERVAL:-1}"
LIVE_TRACE_WARN_MB="${LIVE_TRACE_WARN_MB:-1024}"
RUN_LEDGER="${RUN_LEDGER:-$PWD/reports/performance-runs.jsonl}"

# ── phased profiling templates ──────────────────────────────────────────────
# Each entry: "template|duration|description"
# Ordered to capture: startup → active overlay → idle → memory → cleanup
PHASED_TEMPLATES=(
  "App Launch|12s|Startup cost (dyld, AppKit init, first frame)"
  "Time Profiler|25s|CPU under load (sync engine, SwiftUI, provider calls)"
  "Allocations|30s|Memory under load (lyrics doc, translation cache, overlay)"
  "Leaks|30s|Memory leaks (extended overlay + translation cycle)"
  "SwiftUI|20s|View invalidation and body recomputation cost"
  "System Trace|15s|Wake/idle patterns, context switches, timer fires"
  "Swift Concurrency|20s|Task lifetimes, actor hops, runaway async work"
  "Power Profiler|15s|Energy impact of long-running menu bar presence"
  "Animation Hitches|20s|Overlay rendering smoothness during lyric transitions"
)

usage() {
  cat >&2 <<'EOF'
usage:
  script/profile.sh list
  script/profile.sh record [template] [duration] [--demo] [--live] [--scenario name]
  script/profile.sh phased [--demo] [--live] [--scenario name]
  script/profile.sh sample [duration] [--demo] [--live] [--scenario name]
  script/profile.sh report
  script/profile.sh compare-runs <baseline-run-id> <candidate-run-id>
  script/profile.sh preflight-live
  script/profile.sh disk
  script/profile.sh open [template]
  script/profile.sh compare <trace-a> <trace-b>
  script/profile.sh clean

examples:
  script/profile.sh list
  script/profile.sh record "Time Profiler" 20s
  script/profile.sh record "Allocations" 30s --live --scenario overlay-karaoke
  script/profile.sh phased --live --scenario overlay-karaoke
  script/profile.sh sample 30s --live --scenario overlay-karaoke
  script/profile.sh report
  script/profile.sh compare-runs 20260524-aaa 20260524-bbb
  script/profile.sh preflight-live
  script/profile.sh disk
  script/profile.sh open "SwiftUI"
  script/profile.sh compare traces/0.0.1-Time-Profiler.trace traces/0.0.2-Time-Profiler.trace
  script/profile.sh clean

--demo: Launches the app with the --demo flag, which auto-shows the
        floating lyrics overlay with mock playback, mock lyrics, and
        mock translation — exercising the real hot paths.
--live: Requires Music.app to already be playing a real track, launches the
        app with --live, captures MusicFloat logs, and verifies live playback,
        overlay appearance, and non-mock lyrics before accepting the trace.
--scenario: Names the workflow being measured so future comparisons do not mix
            unrelated evidence.
EOF
}

build_app() {
  /usr/bin/xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    build
}

stop_app() {
  /usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  /usr/bin/killall "$APP_NAME" >/dev/null 2>&1 || true
}

artifact_size() {
  local path="$1"
  if [[ -e "$path" ]]; then
    /usr/bin/du -sh "$path" 2>/dev/null | /usr/bin/awk '{print $1}'
  else
    printf "0B"
  fi
}

print_artifact_usage() {
  echo "  Artifact usage:"
  printf "    traces:      %s (%s)\n" "$(artifact_size "$TRACE_DIR")" "$TRACE_DIR"
  printf "    DerivedData: %s (%s)\n" "$(artifact_size "$DERIVED_DATA_DIR")" "$DERIVED_DATA_DIR"
}

mode_name() {
  local use_demo="$1"
  local use_live="$2"
  if [[ "$use_live" == "true" ]]; then
    printf "live"
  elif [[ "$use_demo" == "true" ]]; then
    printf "demo"
  else
    printf "default"
  fi
}

parse_scenario() {
  local scenario="unspecified"
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --scenario)
        if [[ "$#" -lt 2 ]]; then
          echo "Error: --scenario requires a value" >&2
          exit 2
        fi
        scenario="$2"
        shift 2
        ;;
      --scenario=*)
        scenario="${1#--scenario=}"
        shift
        ;;
      *)
        shift
        ;;
    esac
  done
  printf "%s" "$scenario"
}

parse_sample_duration() {
  local duration="20s"
  local found="false"
  shift || true

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --demo|--live)
        shift
        ;;
      --scenario)
        if [[ "$#" -lt 2 ]]; then
          echo "Error: --scenario requires a value" >&2
          exit 2
        fi
        shift 2
        ;;
      --scenario=*)
        shift
        ;;
      --*)
        echo "Error: unknown sample option: $1" >&2
        exit 2
        ;;
      *)
        if [[ "$found" == "true" ]]; then
          echo "Error: sample accepts only one duration argument." >&2
          exit 2
        fi
        duration="$1"
        found="true"
        shift
        ;;
    esac
  done

  printf "%s" "$duration"
}

duration_to_sleep_seconds() {
  DURATION="$1" /usr/bin/python3 <<'PY'
import os
import re
import sys

duration = os.environ["DURATION"]
match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)(ms|s|m|h)?", duration)
if not match:
    print(f"Error: invalid sample duration: {duration}", file=sys.stderr)
    raise SystemExit(2)

value = float(match.group(1))
unit = match.group(2) or "s"
multiplier = {"ms": 0.001, "s": 1.0, "m": 60.0, "h": 3600.0}[unit]
seconds = value * multiplier
if seconds <= 0:
    print(f"Error: sample duration must be greater than zero: {duration}", file=sys.stderr)
    raise SystemExit(2)

print(f"{seconds:.3f}".rstrip("0").rstrip("."))
PY
}

git_value() {
  git "$@" 2>/dev/null || true
}

app_marketing_version() {
  /usr/bin/awk -F' = ' '/MARKETING_VERSION = / { gsub(/;| /, "", $2); print $2; exit }' "$PROJECT/project.pbxproj"
}

app_build_version() {
  /usr/bin/awk -F' = ' '/CURRENT_PROJECT_VERSION = / { gsub(/;| /, "", $2); print $2; exit }' "$PROJECT/project.pbxproj"
}

current_pr_number() {
  if command -v gh >/dev/null 2>&1; then
    gh pr view --json number --jq .number 2>/dev/null || true
  fi
}

ensure_disk_headroom() {
  local min_free_gb="$1"
  local min_free_kb=$((min_free_gb * 1024 * 1024))
  local available_kb
  available_kb="$(/bin/df -Pk "$PWD" | /usr/bin/awk 'NR == 2 { print $4 }')"

  if [[ -z "$available_kb" || "$available_kb" -lt "$min_free_kb" ]]; then
    echo "Error: profiling needs at least ${min_free_gb}GB free in this workspace." >&2
    print_artifact_usage >&2
    echo "Run: ./script/profile.sh clean" >&2
    exit 1
  fi
}

preflight_live() {
  local info
  set +e
  info="$(/usr/bin/osascript <<'APPLESCRIPT' 2>/dev/null
tell application "System Events"
  set musicRunning to exists process "Music"
end tell
if musicRunning is false then
  return "not_running"
end if

tell application "Music"
  set playbackState to player state as string
  set trackName to ""
  set artistName to ""
  set playerPosition to player position
  try
    set trackName to name of current track
    set artistName to artist of current track
  end try
end tell

return playbackState & tab & trackName & tab & artistName & tab & playerPosition
APPLESCRIPT
)"
  local status="$?"
  set -e

  if [[ "$status" -ne 0 || -z "$info" ]]; then
    echo "Error: could not inspect Music.app playback for --live profiling." >&2
    echo "Start Music.app, play a lyric-capable Apple Music track, then retry." >&2
    exit 1
  fi

  if [[ "$info" == "not_running" ]]; then
    echo "Error: --live profiling requires Music.app to be running and playing." >&2
    exit 1
  fi

  local playback_state track_name artist_name player_position
  playback_state="$(printf "%s" "$info" | /usr/bin/awk -F '\t' '{ print $1 }')"
  track_name="$(printf "%s" "$info" | /usr/bin/awk -F '\t' '{ print $2 }')"
  artist_name="$(printf "%s" "$info" | /usr/bin/awk -F '\t' '{ print $3 }')"
  player_position="$(printf "%s" "$info" | /usr/bin/awk -F '\t' '{ print $4 }')"
  if [[ "$playback_state" != "playing" || -z "$track_name" ]]; then
    echo "Error: --live profiling requires an actively playing Music.app track." >&2
    echo "Current Music state: ${playback_state:-unknown} ${track_name:+- $track_name}" >&2
    exit 1
  fi

  echo "  Live preflight: Music.app is playing \"$track_name\" by ${artist_name:-unknown artist} at ${player_position:-unknown}s."
  echo "  The profiled app will launch with --live, start Live Apple Music mode, and show the overlay."
  echo "  Keep Music playing and visually confirm lyrics appear during the trace."
}

parse_profile_flags() {
  local use_demo="$1"
  local use_live="$2"

  if [[ "$use_demo" == "true" && "$use_live" == "true" ]]; then
    echo "Error: choose either --demo or --live, not both." >&2
    exit 2
  fi
}

start_live_log_capture() {
  local log_path="$1"
  /bin/mkdir -p "$(dirname "$log_path")"
  : > "$log_path"
  /usr/bin/log stream \
    --style compact \
    --level debug \
    --predicate 'subsystem == "cv.MusicFloat"' \
    > "$log_path" 2>&1 &
  echo "$!"
}

start_usage_capture() {
  local usage_path="$1"
  /bin/mkdir -p "$(dirname "$usage_path")"
  printf "timestamp,pid,rss_kb,cpu_pct\n" > "$usage_path"
  (
    set +e
    while true; do
      pid=""
      pid="$(/usr/bin/pgrep -x "$APP_NAME" | /usr/bin/head -n 1 || true)"
      if [[ -n "$pid" ]]; then
        /bin/ps -o pid=,rss=,%cpu= -p "$pid" | /usr/bin/awk -v ts="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" '
          NF >= 3 { printf "%s,%s,%s,%s\n", ts, $1, $2, $3 }
        ' >> "$usage_path" || true
      fi
      /bin/sleep "$USAGE_SAMPLE_INTERVAL"
    done
  ) >/dev/null 2>&1 &
  echo "$!"
}

stop_usage_capture() {
  local usage_pid="${1:-}"
  if [[ -n "$usage_pid" ]]; then
    /bin/kill "$usage_pid" >/dev/null 2>&1 || true
    wait "$usage_pid" >/dev/null 2>&1 || true
  fi
}

summarize_usage_capture() {
  local usage_path="$1"
  if [[ ! -s "$usage_path" ]]; then
    echo "  Usage samples: none captured ($usage_path)"
    return 1
  fi

  /usr/bin/awk -F, '
    NR > 1 && NF >= 4 && $3 > 1024 {
      count += 1
      rss += $3
      cpu += $4
      if ($3 > max_rss) { max_rss = $3 }
      if ($4 > max_cpu) { max_cpu = $4 }
    }
    END {
      if (count == 0) {
        printf "  Usage samples: none credible captured\n"
        exit 1
      }
      printf "  Usage samples: %d avgRSS=%.1fMB maxRSS=%.1fMB avgCPU=%.2f%% maxCPU=%.2f%%\n", count, rss / count / 1024, max_rss / 1024, cpu / count, max_cpu
    }
  ' "$usage_path"
  echo "  Usage CSV: $usage_path"
}

append_run_ledger() {
  local run_id="$1"
  local kind="$2"
  local mode="$3"
  local scenario="$4"
  local duration="$5"
  local template="$6"
  local status="$7"
  local valid="$8"
  local trace_path="$9"
  local usage_path="${10}"
  local live_log_path="${11}"
  local failure_reason="${12:-}"

  /bin/mkdir -p "$(dirname "$RUN_LEDGER")"
  RUN_ID="$run_id" \
  RUN_KIND="$kind" \
  RUN_MODE="$mode" \
  RUN_SCENARIO="$scenario" \
  RUN_DURATION="$duration" \
  RUN_TEMPLATE="$template" \
  RUN_STATUS="$status" \
  RUN_VALID="$valid" \
  RUN_CREATED_AT="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" \
  RUN_TRACE_PATH="$trace_path" \
  RUN_USAGE_PATH="$usage_path" \
  RUN_LIVE_LOG_PATH="$live_log_path" \
  RUN_FAILURE_REASON="$failure_reason" \
  RUN_LEDGER="$RUN_LEDGER" \
  RUN_WORKSPACE="$PWD" \
  RUN_BRANCH="$(git_value branch --show-current)" \
  RUN_COMMIT="$(git_value rev-parse HEAD)" \
  RUN_EXACT_TAG="$(git_value describe --tags --exact-match HEAD)" \
  RUN_NEAREST_TAG="$(git_value describe --tags --abbrev=8 --always HEAD)" \
  RUN_PR_NUMBER="$(current_pr_number)" \
  RUN_MARKETING_VERSION="$(app_marketing_version)" \
  RUN_BUILD_VERSION="$(app_build_version)" \
  RUN_TRACKED_DIRTY="$([[ -n "$(git status --porcelain --untracked-files=no)" ]] && printf true || printf false)" \
  RUN_UNTRACKED_COUNT="$(git status --porcelain --untracked-files=all | /usr/bin/awk '/^\\?\\?/ { count += 1 } END { print count + 0 }')" \
  /usr/bin/python3 <<'PY'
import csv
import json
import os
from pathlib import Path

def env(name, default=""):
    return os.environ.get(name, default)

workspace = Path(env("RUN_WORKSPACE")).resolve()
usage_path = env("RUN_USAGE_PATH")
trace_path = env("RUN_TRACE_PATH")
samples = []
if usage_path and Path(usage_path).is_file():
    with open(usage_path, newline="") as f:
        for row in csv.DictReader(f):
            try:
                rss = float(row.get("rss_kb") or 0)
                cpu = float(row.get("cpu_pct") or 0)
            except ValueError:
                continue
            if rss > 1024:
                samples.append((rss, cpu))

usage = {
    "samples": len(samples),
    "avg_rss_mb": None,
    "max_rss_mb": None,
    "avg_cpu_pct": None,
    "max_cpu_pct": None,
}
if samples:
    usage["avg_rss_mb"] = round(sum(r for r, _ in samples) / len(samples) / 1024, 2)
    usage["max_rss_mb"] = round(max(r for r, _ in samples) / 1024, 2)
    usage["avg_cpu_pct"] = round(sum(c for _, c in samples) / len(samples), 2)
    usage["max_cpu_pct"] = round(max(c for _, c in samples), 2)

trace_size_mb = None
if trace_path and Path(trace_path).exists():
    if Path(trace_path).is_dir():
        trace_size = sum(p.stat().st_size for p in Path(trace_path).rglob("*") if p.is_file())
    else:
        trace_size = Path(trace_path).stat().st_size
    trace_size_mb = round(trace_size / 1024 / 1024, 2)

def artifact_path(path):
    if not path:
        return None
    p = Path(path)
    if not p.is_absolute():
        return path
    try:
        return str(p.resolve().relative_to(workspace))
    except ValueError:
        return str(p)

record = {
    "schema": 1,
    "run_id": env("RUN_ID"),
    "timestamp_utc": env("RUN_CREATED_AT"),
    "kind": env("RUN_KIND"),
    "mode": env("RUN_MODE"),
    "scenario": env("RUN_SCENARIO"),
    "duration": env("RUN_DURATION"),
    "template": env("RUN_TEMPLATE"),
    "status": env("RUN_STATUS"),
    "valid": env("RUN_VALID") == "true",
    "failure_reason": env("RUN_FAILURE_REASON") or None,
    "git": {
        "branch": env("RUN_BRANCH"),
        "commit": env("RUN_COMMIT"),
        "exact_tag": env("RUN_EXACT_TAG") or None,
        "nearest_tag": env("RUN_NEAREST_TAG") or None,
        "pr_number": int(env("RUN_PR_NUMBER")) if env("RUN_PR_NUMBER").isdigit() else None,
        "tracked_dirty": env("RUN_TRACKED_DIRTY") == "true",
        "untracked_count": int(env("RUN_UNTRACKED_COUNT") or 0),
    },
    "app": {
        "marketing_version": env("RUN_MARKETING_VERSION") or None,
        "build_version": env("RUN_BUILD_VERSION") or None,
    },
    "usage": usage,
    "artifacts": {
        "trace_path": artifact_path(trace_path),
        "trace_size_mb": trace_size_mb,
        "usage_csv": artifact_path(usage_path),
        "live_log": artifact_path(env("RUN_LIVE_LOG_PATH")),
    },
}

with open(env("RUN_LEDGER"), "a") as f:
    f.write(json.dumps(record, separators=(",", ":")) + "\n")
PY
  echo "  Run ledger: $RUN_LEDGER ($run_id)"
}

stop_live_log_capture() {
  local log_pid="${1:-}"
  if [[ -n "$log_pid" ]]; then
    /bin/kill "$log_pid" >/dev/null 2>&1 || true
    wait "$log_pid" >/dev/null 2>&1 || true
  fi
}

require_live_log_pattern() {
  local log_path="$1"
  local pattern="$2"
  local description="$3"
  if ! /usr/bin/grep -E "$pattern" "$log_path" >/dev/null; then
    echo "Error: live trace verification failed: missing $description" >&2
    echo "       log: $log_path" >&2
    return 1
  fi
}

verify_live_recording() {
  local log_path="$1"
  local trace_path="$2"

  verify_live_log "$log_path"

  local trace_kb
  trace_kb="$(/usr/bin/du -sk "$trace_path" | /usr/bin/awk '{print $1}')"
  local trace_mb=$(( (trace_kb + 1023) / 1024 ))
  echo "  Trace disk usage: ${trace_mb}MB ($trace_path)"
  if (( trace_mb > LIVE_TRACE_WARN_MB )); then
    echo "  Warning: trace exceeds LIVE_TRACE_WARN_MB=${LIVE_TRACE_WARN_MB}MB"
  fi
}

verify_live_log() {
  local log_path="$1"

  require_live_log_pattern "$log_path" "Live mode requested" "live launch"
  require_live_log_pattern "$log_path" "Live Apple Music bridge started" "live bridge start"
  require_live_log_pattern "$log_path" "Live prime: status=playing hasTrack=true" "playing Apple Music prime"
  require_live_log_pattern "$log_path" "Toggle overlay requested visible=true" "overlay toggle"
  require_live_log_pattern "$log_path" "Lyrics overlay view appeared" "overlay appearance"
  require_live_log_pattern "$log_path" "Lyrics document applied source=(appleMusicWeb|lrclib|musicApp|musicAppUI|publicProvider)" "non-mock lyrics document"
  require_live_log_pattern "$log_path" "Provider pipeline ready" "provider ready state"

  echo "  Live verification: playback, overlay, and non-mock lyrics confirmed"
  echo "  Live verification log: $log_path"
}

# ── record_one: records a single template ───────────────────────────────────
# Args: template duration use_demo use_live scenario
record_one() {
  local template="$1"
  local duration="$2"
  local use_demo="${3:-false}"
  local use_live="${4:-false}"
  local scenario="${5:-unspecified}"
  local timestamp
  timestamp="$(/bin/date -u +%Y%m%d-%H%M%SZ)"
  local safe_name="${template// /-}"
  local run_id="${timestamp}-$(mode_name "$use_demo" "$use_live")-${safe_name}-$(git_value rev-parse --short HEAD)"
  local trace_path="$TRACE_DIR/${APP_NAME}-${safe_name}-$timestamp.trace"
  local live_log_path="$LIVE_LOG_DIR/${APP_NAME}-${safe_name}-$timestamp.live.log"
  local ledger_live_log_path=""
  local usage_log_path="$USAGE_LOG_DIR/${APP_NAME}-${safe_name}-$timestamp.usage.csv"
  local live_log_pid=""
  local usage_log_pid=""

  /bin/mkdir -p "$TRACE_DIR"
  stop_app

  local launch_args=("$APP_EXEC")
  if [[ "$use_demo" == "true" ]]; then
    launch_args+=("--demo")
  elif [[ "$use_live" == "true" ]]; then
    launch_args+=("--live")
  fi

  if [[ "$use_live" == "true" ]]; then
    ledger_live_log_path="$live_log_path"
    live_log_pid="$(start_live_log_capture "$live_log_path")"
    /bin/sleep 0.5
  fi
  usage_log_pid="$(start_usage_capture "$usage_log_path")"

  printf "  \033[1;36m▶\033[0m %-22s (%s) ... " "$template" "$duration"
  set +e
  local record_output
  record_output="$(/usr/bin/xcrun xctrace record \
    --template "$template" \
    --time-limit "$duration" \
    --output "$trace_path" \
    --launch -- "${launch_args[@]}" 2>&1)"
  local record_status="$?"
  set -e

  stop_app
  stop_usage_capture "$usage_log_pid"
  stop_live_log_capture "$live_log_pid"

  if [[ "$record_status" -ne 0 ]]; then
    printf "\033[1;31mFAILED\033[0m\n   %s\n" "$record_output"
    append_run_ledger "$run_id" "record" "$(mode_name "$use_demo" "$use_live")" "$scenario" "$duration" "$template" "failed" "false" "$trace_path" "$usage_log_path" "$ledger_live_log_path" "xctrace exited non-zero"
    return 1
  fi

  if [[ "$use_live" == "true" ]]; then
    if ! verify_live_recording "$live_log_path" "$trace_path"; then
      printf "\033[1;31mFAILED\033[0m\n"
      append_run_ledger "$run_id" "record" "$(mode_name "$use_demo" "$use_live")" "$scenario" "$duration" "$template" "failed" "false" "$trace_path" "$usage_log_path" "$ledger_live_log_path" "live verification failed"
      return 1
    fi
  fi
  if ! summarize_usage_capture "$usage_log_path"; then
    printf "\033[1;31mFAILED\033[0m\n"
    append_run_ledger "$run_id" "record" "$(mode_name "$use_demo" "$use_live")" "$scenario" "$duration" "$template" "failed" "false" "$trace_path" "$usage_log_path" "$ledger_live_log_path" "usage capture failed"
    return 1
  fi
  append_run_ledger "$run_id" "record" "$(mode_name "$use_demo" "$use_live")" "$scenario" "$duration" "$template" "passed" "true" "$trace_path" "$usage_log_path" "$ledger_live_log_path"

  printf "\033[1;32m✓\033[0m %s\n" "$trace_path"
  return 0
}

# ── record (single template) ────────────────────────────────────────────────
do_record() {
  local template="${2:-Time Profiler}"
  local duration="${3:-20s}"
  local use_demo="false"
  local use_live="false"
  local scenario
  scenario="$(parse_scenario "$@")"

  # Parse flags (can be anywhere after mode)
  for arg in "$@"; do
    [[ "$arg" == "--demo" ]] && use_demo="true"
    [[ "$arg" == "--live" ]] && use_live="true"
  done
  parse_profile_flags "$use_demo" "$use_live"
  ensure_disk_headroom 2
  if [[ "$use_live" == "true" ]]; then
    preflight_live
  fi

  build_app
  echo ""
  echo "  Recording: $template ($duration)"
  echo "  Demo mode: $use_demo"
  echo "  Live mode: $use_live"
  echo ""

  record_one "$template" "$duration" "$use_demo" "$use_live" "$scenario"
  print_artifact_usage
}

# ── phased (all templates in sequence) ──────────────────────────────────────
do_phased() {
  local use_demo="false"
  local use_live="false"
  local scenario
  scenario="$(parse_scenario "$@")"
  for arg in "$@"; do
    [[ "$arg" == "--demo" ]] && use_demo="true"
    [[ "$arg" == "--live" ]] && use_live="true"
  done
  parse_profile_flags "$use_demo" "$use_live"
  ensure_disk_headroom 8
  if [[ "$use_live" == "true" ]]; then
    preflight_live
  fi

  build_app

  local total=${#PHASED_TEMPLATES[@]}
  local passed=0
  local failed=0
  local traces=()

  echo ""
  echo "  ═══════════════════════════════════════════════════════════"
  printf "  Phased profiling: %d templates | Demo: %s | Live: %s\n" "$total" "$use_demo" "$use_live"
  echo "  ═══════════════════════════════════════════════════════════"
  echo ""

  local i=1
  for entry in "${PHASED_TEMPLATES[@]}"; do
    IFS='|' read -r template duration desc <<< "$entry"
    printf "  [%d/%d] %s\n" "$i" "$total" "$desc"
    if record_one "$template" "$duration" "$use_demo" "$use_live" "$scenario"; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
    fi
    i=$((i + 1))
    echo ""
  done

  echo "  ═══════════════════════════════════════════════════════════"
  printf "  Results: \033[1;32m%d passed\033[0m" "$passed"
  if [[ "$failed" -gt 0 ]]; then
    printf ", \033[1;31m%d failed\033[0m" "$failed"
  fi
  printf " of %d templates\n" "$total"
  echo "  ═══════════════════════════════════════════════════════════"
  print_artifact_usage
}

# ── sample: direct run with ps-based CPU/RSS sampling ───────────────────────
do_sample() {
  local duration
  duration="$(parse_sample_duration "$@")"
  local use_demo="false"
  local use_live="false"
  local scenario
  scenario="$(parse_scenario "$@")"
  for arg in "$@"; do
    [[ "$arg" == "--demo" ]] && use_demo="true"
    [[ "$arg" == "--live" ]] && use_live="true"
  done
  parse_profile_flags "$use_demo" "$use_live"
  ensure_disk_headroom 1
  if [[ "$use_live" == "true" ]]; then
    preflight_live
  fi

  build_app

  local seconds
  seconds="$(duration_to_sleep_seconds "$duration")"
  local timestamp safe_name usage_log_path live_log_path ledger_live_log_path live_log_pid usage_log_pid
  timestamp="$(/bin/date -u +%Y%m%d-%H%M%SZ)"
  safe_name="Direct-Sample"
  local run_id="${timestamp}-$(mode_name "$use_demo" "$use_live")-${safe_name}-$(git_value rev-parse --short HEAD)"
  usage_log_path="$USAGE_LOG_DIR/${APP_NAME}-${safe_name}-$timestamp.usage.csv"
  live_log_path="$LIVE_LOG_DIR/${APP_NAME}-${safe_name}-$timestamp.live.log"
  ledger_live_log_path=""
  live_log_pid=""
  usage_log_pid=""

  stop_app
  local launch_args=("$APP_EXEC")
  if [[ "$use_demo" == "true" ]]; then
    launch_args+=("--demo")
  elif [[ "$use_live" == "true" ]]; then
    launch_args+=("--live")
  fi

  if [[ "$use_live" == "true" ]]; then
    ledger_live_log_path="$live_log_path"
    live_log_pid="$(start_live_log_capture "$live_log_path")"
    /bin/sleep 0.5
  fi

  echo "  Direct sample: ${duration} | Demo: $use_demo | Live: $use_live"
  "${launch_args[@]}" >/dev/null 2>&1 &
  usage_log_pid="$(start_usage_capture "$usage_log_path")"
  /bin/sleep "$seconds"
  stop_app
  stop_usage_capture "$usage_log_pid"
  stop_live_log_capture "$live_log_pid"

  if [[ "$use_live" == "true" ]]; then
    if ! verify_live_log "$live_log_path"; then
      summarize_usage_capture "$usage_log_path" || true
      append_run_ledger "$run_id" "sample" "$(mode_name "$use_demo" "$use_live")" "$scenario" "$duration" "" "failed" "false" "" "$usage_log_path" "$ledger_live_log_path" "live verification failed"
      return 1
    fi
  fi
  if ! summarize_usage_capture "$usage_log_path"; then
    append_run_ledger "$run_id" "sample" "$(mode_name "$use_demo" "$use_live")" "$scenario" "$duration" "" "failed" "false" "" "$usage_log_path" "$ledger_live_log_path" "usage capture failed"
    return 1
  fi
  append_run_ledger "$run_id" "sample" "$(mode_name "$use_demo" "$use_live")" "$scenario" "$duration" "" "passed" "true" "" "$usage_log_path" "$ledger_live_log_path"
  print_artifact_usage
}

# ── compare: open two traces side-by-side in Instruments ────────────────────
do_compare() {
  local trace_a="$2"
  local trace_b="$3"

  if [[ ! -d "$trace_a" ]]; then
    echo "Error: trace not found: $trace_a" >&2
    exit 1
  fi
  if [[ ! -d "$trace_b" ]]; then
    echo "Error: trace not found: $trace_b" >&2
    exit 1
  fi

  echo "Opening Instruments with:"
  echo "  A: $trace_a"
  echo "  B: $trace_b"
  /usr/bin/open -a Instruments --args "$trace_a" "$trace_b"
}

# ── report: summarize durable run ledger ───────────────────────────────────
do_report() {
  RUN_LEDGER="$RUN_LEDGER" /usr/bin/python3 <<'PY'
import json
import os
from pathlib import Path

ledger = Path(os.environ["RUN_LEDGER"])
if not ledger.exists():
    print(f"No performance runs recorded yet: {ledger}")
    raise SystemExit(0)

runs = []
with ledger.open() as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            runs.append(json.loads(line))
        except json.JSONDecodeError:
            continue

if not runs:
    print(f"No readable performance runs in: {ledger}")
    raise SystemExit(0)

print(f"Performance runs: {len(runs)} ({ledger})")
for run in runs[-12:]:
    usage = run.get("usage", {})
    git = run.get("git", {})
    app = run.get("app", {})
    print(
        "{run_id} | {status} | {mode}/{scenario} | pr={pr} | {branch}@{commit} | "
        "v={version} | avgRSS={rss}MB maxCPU={cpu}% | valid={valid}".format(
            run_id=run.get("run_id"),
            status=run.get("status"),
            mode=run.get("mode"),
            scenario=run.get("scenario"),
            pr=git.get("pr_number") or "-",
            branch=git.get("branch") or "-",
            commit=(git.get("commit") or "")[:8],
            version=app.get("marketing_version") or "-",
            rss=usage.get("avg_rss_mb"),
            cpu=usage.get("max_cpu_pct"),
            valid=run.get("valid"),
        )
    )
PY
}

# ── compare-runs: compare two ledger entries ───────────────────────────────
do_compare_runs() {
  local baseline_id="${2:-}"
  local candidate_id="${3:-}"
  if [[ -z "$baseline_id" || -z "$candidate_id" ]]; then
    echo "usage: script/profile.sh compare-runs <baseline-run-id> <candidate-run-id>" >&2
    exit 2
  fi

  BASELINE_RUN_ID="$baseline_id" CANDIDATE_RUN_ID="$candidate_id" RUN_LEDGER="$RUN_LEDGER" /usr/bin/python3 <<'PY'
import json
import os
from pathlib import Path

ledger = Path(os.environ["RUN_LEDGER"])
baseline_id = os.environ["BASELINE_RUN_ID"]
candidate_id = os.environ["CANDIDATE_RUN_ID"]

runs = {}
if ledger.exists():
    with ledger.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                run = json.loads(line)
            except json.JSONDecodeError:
                continue
            runs[run.get("run_id")] = run

missing = [rid for rid in (baseline_id, candidate_id) if rid not in runs]
if missing:
    print(f"Missing run id(s): {', '.join(missing)}")
    raise SystemExit(1)

a = runs[baseline_id]
b = runs[candidate_id]

def metric(run, key):
    return run.get("usage", {}).get(key)

def delta(key):
    av = metric(a, key)
    bv = metric(b, key)
    if av is None or bv is None:
        return "n/a"
    raw = bv - av
    pct = (raw / av * 100) if av else 0
    return f"{raw:+.2f} ({pct:+.1f}%)"

print(f"Baseline:  {baseline_id} {a.get('mode')}/{a.get('scenario')} {a.get('git', {}).get('branch')}@{(a.get('git', {}).get('commit') or '')[:8]}")
print(f"Candidate: {candidate_id} {b.get('mode')}/{b.get('scenario')} {b.get('git', {}).get('branch')}@{(b.get('git', {}).get('commit') or '')[:8]}")

if a.get("mode") != b.get("mode"):
    print("WARNING: mixed-mode comparison; do not treat as regression evidence.")
if a.get("scenario") != b.get("scenario"):
    print("WARNING: scenario differs; compare cautiously.")
if not a.get("valid") or not b.get("valid"):
    print("WARNING: at least one run is invalid.")

print("Deltas candidate - baseline:")
print(f"  avg RSS: {delta('avg_rss_mb')}")
print(f"  max RSS: {delta('max_rss_mb')}")
print(f"  avg CPU: {delta('avg_cpu_pct')}")
print(f"  max CPU: {delta('max_cpu_pct')}")

trace_a = a.get("artifacts", {}).get("trace_size_mb")
trace_b = b.get("artifacts", {}).get("trace_size_mb")
if trace_a is not None and trace_b is not None:
    raw = trace_b - trace_a
    pct = (raw / trace_a * 100) if trace_a else 0
    print(f"  trace size: {raw:+.2f}MB ({pct:+.1f}%)")
PY
}

# ── clean: wipe out generated traces and local DerivedData ──────────────────
do_clean() {
  echo "Cleaning up profiling artifacts..."
  if [[ -d "$TRACE_DIR" ]]; then
    echo "  Removing trace bundles from: $TRACE_DIR"
    /bin/rm -rf "$TRACE_DIR"/*
  else
    echo "  No traces folder found."
  fi
  if [[ -d "$DERIVED_DATA_DIR" ]]; then
    echo "  Removing local DerivedData: $DERIVED_DATA_DIR"
    /bin/rm -rf "$DERIVED_DATA_DIR"
  else
    echo "  No local DerivedData folder found."
  fi
  # Clean local Xcode coverage raw profiles if any
  if [[ -f "$PWD/default.profraw" ]]; then
    echo "  Removing default.profraw"
    /bin/rm -f "$PWD/default.profraw"
  fi
  echo "Cleanup complete!"
}

# ── main dispatch ───────────────────────────────────────────────────────────
mode="${1:-list}"
case "$mode" in
  list)
    /usr/bin/xcrun xctrace list templates
    ;;
  record)
    do_record "$@"
    ;;
  phased)
    do_phased "$@"
    ;;
  sample)
    do_sample "$@"
    ;;
  report)
    do_report
    ;;
  compare-runs)
    do_compare_runs "$@"
    ;;
  preflight-live)
    preflight_live
    ;;
  disk)
    print_artifact_usage
    ;;
  open)
    template="${2:-Time Profiler}"
    /usr/bin/open -a Instruments --args -t "$template"
    ;;
  compare)
    do_compare "$@"
    ;;
  clean)
    do_clean
    ;;
  *)
    usage
    exit 2
    ;;
esac
