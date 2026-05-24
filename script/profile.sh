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
  script/profile.sh record [template] [duration] [--demo]
  script/profile.sh phased [--demo]
  script/profile.sh open [template]
  script/profile.sh compare <trace-a> <trace-b>

examples:
  script/profile.sh list
  script/profile.sh record "Time Profiler" 20s
  script/profile.sh record "Allocations" 30s --demo
  script/profile.sh phased --demo
  script/profile.sh open "SwiftUI"
  script/profile.sh compare traces/0.0.1-Time-Profiler.trace traces/0.0.2-Time-Profiler.trace

--demo: Launches the app with the --demo flag, which auto-shows the
        floating lyrics overlay with mock playback, mock lyrics, and
        mock translation — exercising the real hot paths.
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

# ── record_one: records a single template ───────────────────────────────────
# Args: template duration use_demo
record_one() {
  local template="$1"
  local duration="$2"
  local use_demo="${3:-false}"
  local timestamp
  timestamp="$(/bin/date +%Y%m%d-%H%M%S)"
  local safe_name="${template// /-}"
  local trace_path="$TRACE_DIR/${APP_NAME}-${safe_name}-$timestamp.trace"

  /bin/mkdir -p "$TRACE_DIR"
  stop_app

  local launch_args=("$APP_EXEC")
  if [[ "$use_demo" == "true" ]]; then
    launch_args+=("--demo")
  fi

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

  if [[ "$record_status" -ne 0 && ! -d "$trace_path" ]]; then
    printf "\033[1;31mFAILED\033[0m\n   %s\n" "$record_output"
    return 1
  fi

  printf "\033[1;32m✓\033[0m %s\n" "$trace_path"
  return 0
}

# ── record (single template) ────────────────────────────────────────────────
do_record() {
  local template="${2:-Time Profiler}"
  local duration="${3:-20s}"
  local use_demo="false"

  # Parse --demo flag (can be anywhere after mode)
  for arg in "$@"; do
    [[ "$arg" == "--demo" ]] && use_demo="true"
  done

  build_app
  echo ""
  echo "  Recording: $template ($duration)"
  echo "  Demo mode: $use_demo"
  echo ""

  record_one "$template" "$duration" "$use_demo"
}

# ── phased (all templates in sequence) ──────────────────────────────────────
do_phased() {
  local use_demo="false"
  for arg in "$@"; do
    [[ "$arg" == "--demo" ]] && use_demo="true"
  done

  build_app

  local total=${#PHASED_TEMPLATES[@]}
  local passed=0
  local failed=0
  local traces=()

  echo ""
  echo "  ═══════════════════════════════════════════════════════════"
  printf "  Phased profiling: %d templates | Demo: %s\n" "$total" "$use_demo"
  echo "  ═══════════════════════════════════════════════════════════"
  echo ""

  local i=1
  for entry in "${PHASED_TEMPLATES[@]}"; do
    IFS='|' read -r template duration desc <<< "$entry"
    printf "  [%d/%d] %s\n" "$i" "$total" "$desc"
    if record_one "$template" "$duration" "$use_demo"; then
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
  open)
    template="${2:-Time Profiler}"
    /usr/bin/open -a Instruments --args -t "$template"
    ;;
  compare)
    do_compare "$@"
    ;;
  *)
    usage
    exit 2
    ;;
esac
