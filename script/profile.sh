#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MusicFloat"
PROJECT="MusicFloat.xcodeproj"
SCHEME="MusicFloat"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-$PWD/.codex/DerivedData}"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
TRACE_DIR="${TRACE_DIR:-$PWD/.codex/traces}"

usage() {
  cat >&2 <<'EOF'
usage:
  script/profile.sh list
  script/profile.sh record [template] [duration]
  script/profile.sh open [template]

examples:
  script/profile.sh list
  script/profile.sh record "Time Profiler" 20s
  script/profile.sh record "Allocations" 30s
  script/profile.sh record "Logging" 15s
  script/profile.sh open "SwiftUI"
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

mode="${1:-list}"
case "$mode" in
  list)
    /usr/bin/xcrun xctrace list templates
    ;;
  record)
    template="${2:-Time Profiler}"
    duration="${3:-20s}"
    timestamp="$(/bin/date +%Y%m%d-%H%M%S)"
    trace_path="$TRACE_DIR/${APP_NAME}-${template// /-}-$timestamp.trace"

    /bin/mkdir -p "$TRACE_DIR"
    stop_app
    build_app

    set +e
    record_output="$(/usr/bin/xcrun xctrace record \
      --template "$template" \
      --time-limit "$duration" \
      --output "$trace_path" \
      --launch -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>&1)"
    record_status="$?"
    set -e

    printf "%s\n" "$record_output"
    stop_app

    if [[ "$record_status" -ne 0 && ! -d "$trace_path" ]]; then
      exit "$record_status"
    fi

    echo "$trace_path"
    ;;
  open)
    template="${2:-Time Profiler}"
    /usr/bin/open -a Instruments --args -t "$template"
    ;;
  *)
    usage
    exit 2
    ;;
esac
