#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MusicFloat"
PROJECT="MusicFloat.xcodeproj"
SCHEME="MusicFloat"
CONFIGURATION="Release"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-$PWD/.codex/DerivedData}"
BUILT_BUNDLE="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
DIST_DIR="${DIST_DIR:-$PWD/dist}"
EXPORT_BUNDLE="$DIST_DIR/$APP_NAME.app"
INSTALL_TARGET="/Applications/$APP_NAME.app"

usage() {
  cat >&2 <<'EOF'
usage:
  script/release_self.sh [--install] [--open] [--memory]

Builds a local Release app bundle into dist/MusicFloat.app with release-strip
postprocessing enabled. --install copies that bundle to /Applications.
EOF
}

install_app=false
open_app=false
sample_memory=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)
      install_app=true
      ;;
    --open)
      open_app=true
      ;;
    --memory)
      open_app=true
      sample_memory=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
  shift
done

stop_app() {
  /usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  /usr/bin/killall "$APP_NAME" >/dev/null 2>&1 || true
}

wait_for_pid() {
  local bundle="$1"
  local attempt
  local pid
  local command

  for attempt in {1..30}; do
    while IFS= read -r pid; do
      command="$(/bin/ps -o command= -p "$pid" 2>/dev/null || true)"
      if [[ "$command" == "$bundle/Contents/MacOS/$APP_NAME"* ]]; then
        echo "$pid"
        return 0
      fi
    done < <(/usr/bin/pgrep -x "$APP_NAME" || true)
    /bin/sleep 0.2
  done

  return 1
}

sample_process_memory() {
  local pid="$1"
  /bin/ps -o pid=,rss=,vsz=,command= -p "$pid" | /usr/bin/awk '
    {
      rss_mb = $2 / 1024
      vsz_mb = $3 / 1024
      printf "pid=%s rss=%.1fMB vsz=%.1fMB command=", $1, rss_mb, vsz_mb
      for (i = 4; i <= NF; i++) {
        printf "%s%s", $i, (i == NF ? ORS : OFS)
      }
    }'
  /usr/bin/vmmap -summary "$pid" 2>/dev/null | /usr/bin/awk '
    /Physical footprint:/ {
      print "physical_footprint=" $3
    }
    /Physical footprint \(peak\):/ {
      print "physical_footprint_peak=" $4
    }'
}

stop_app

/usr/bin/xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  DEPLOYMENT_POSTPROCESSING=YES \
  COPY_PHASE_STRIP=YES \
  STRIP_INSTALLED_PRODUCT=YES \
  CLANG_COVERAGE_MAPPING=NO \
  GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=NO \
  GCC_GENERATE_TEST_COVERAGE_FILES=NO \
  build

/bin/mkdir -p "$DIST_DIR"
/bin/rm -rf "$EXPORT_BUNDLE"
/usr/bin/ditto "$BUILT_BUNDLE" "$EXPORT_BUNDLE"

echo "exported=$EXPORT_BUNDLE"
echo -n "LSUIElement="
/usr/bin/plutil -extract LSUIElement raw "$EXPORT_BUNDLE/Contents/Info.plist"

echo "signature:"
/usr/bin/codesign -dvv "$EXPORT_BUNDLE" 2>&1 | /usr/bin/sed -n '1,12p'

echo "entitlements:"
/usr/bin/codesign -d --entitlements :- "$EXPORT_BUNDLE" 2>/dev/null | /usr/bin/plutil -p - 2>/dev/null || true

if [[ "$install_app" == true ]]; then
  stop_app
  /bin/rm -rf "$INSTALL_TARGET"
  /usr/bin/ditto "$EXPORT_BUNDLE" "$INSTALL_TARGET"
  echo "installed=$INSTALL_TARGET"
fi

if [[ "$open_app" == true ]]; then
  launch_bundle="$EXPORT_BUNDLE"
  if [[ "$install_app" == true ]]; then
    launch_bundle="$INSTALL_TARGET"
  fi

  /usr/bin/open -n "$launch_bundle"
  pid="$(wait_for_pid "$launch_bundle")"
  echo "pid=$pid"

  if [[ "$sample_memory" == true ]]; then
    /bin/sleep 2
    sample_process_memory "$pid"
  fi
fi
