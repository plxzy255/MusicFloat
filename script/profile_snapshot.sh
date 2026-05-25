#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNAPSHOT_BASE="${SNAPSHOT_BASE:-/private/tmp/musicfloat-profile-snapshots}"
MODE="current"
REF="HEAD"
RUN_COMMAND="false"
SNAPSHOT_NAME=""
COMMAND=()

usage() {
  cat >&2 <<'EOF'
usage:
  script/profile_snapshot.sh [--name name] [--root dir] [--run] [-- command...]
  script/profile_snapshot.sh --ref ref [--name name] [--root dir] [--run] [-- command...]

Creates an isolated temporary worktree for clean profiling evidence.

Default mode snapshots the current working tree into a temporary commit without
changing the main checkout. Use --ref to create a clean snapshot from a branch,
tag, or commit instead.

The helper keeps profiling artifacts outside the snapshot worktree by setting:
  RUN_LEDGER=<snapshot-root>/runs.jsonl
  TRACE_DIR=<snapshot-root>/traces
  DERIVED_DATA_DIR=<snapshot-root>/DerivedData

examples:
  script/profile_snapshot.sh
  script/profile_snapshot.sh -- ./script/profile.sh sample 30s --demo --scenario overlay-karaoke
  script/profile_snapshot.sh --run -- ./script/profile.sh sample 30s --demo --scenario overlay-karaoke
  script/profile_snapshot.sh --ref main -- ./script/profile.sh sample 30s --demo --scenario overlay-karaoke
  script/profile_snapshot.sh --run -- ./script/profile.sh sample 30s --demo --apple-translation --scenario translation-enabled-overlay
EOF
}

quote_command() {
  local word
  for word in "$@"; do
    printf "%q " "$word"
  done
}

print_profile_env_command() {
  local snapshot_dir="$1"
  local run_ledger="$2"
  local trace_dir="$3"
  local derived_data_dir="$4"
  shift 4

  printf "cd %q\n" "$snapshot_dir"
  printf "RUN_LEDGER=%q TRACE_DIR=%q DERIVED_DATA_DIR=%q " "$run_ledger" "$trace_dir" "$derived_data_dir"
  quote_command "$@"
  printf "\n"
}

copy_untracked_files() {
  local source_dir="$1"
  local snapshot_dir="$2"
  local count=0
  local path

  while IFS= read -r -d '' path; do
    /bin/mkdir -p "$snapshot_dir/$(/usr/bin/dirname "$path")"
    /bin/cp -Pp "$source_dir/$path" "$snapshot_dir/$path"
    count=$((count + 1))
  done < <(/usr/bin/git -C "$source_dir" ls-files --others --exclude-standard -z)

  printf "%s" "$count"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --root)
      if [[ "$#" -lt 2 ]]; then
        echo "Error: --root requires a directory" >&2
        exit 2
      fi
      SNAPSHOT_BASE="$2"
      shift 2
      ;;
    --root=*)
      SNAPSHOT_BASE="${1#--root=}"
      shift
      ;;
    --name)
      if [[ "$#" -lt 2 ]]; then
        echo "Error: --name requires a value" >&2
        exit 2
      fi
      SNAPSHOT_NAME="$2"
      shift 2
      ;;
    --name=*)
      SNAPSHOT_NAME="${1#--name=}"
      shift
      ;;
    --ref)
      if [[ "$#" -lt 2 ]]; then
        echo "Error: --ref requires a branch, tag, or commit" >&2
        exit 2
      fi
      MODE="ref"
      REF="$2"
      shift 2
      ;;
    --ref=*)
      MODE="ref"
      REF="${1#--ref=}"
      shift
      ;;
    --current)
      MODE="current"
      REF="HEAD"
      shift
      ;;
    --run)
      RUN_COMMAND="true"
      shift
      ;;
    --)
      shift
      COMMAND=("$@")
      break
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ "$RUN_COMMAND" == "true" && "${#COMMAND[@]}" -eq 0 ]]; then
  echo "Error: --run requires a command after --" >&2
  exit 2
fi

if [[ -n "$(/usr/bin/git -C "$ROOT_DIR" diff --name-only --diff-filter=U)" ]]; then
  echo "Error: unresolved merge conflicts in the source checkout; refusing to snapshot." >&2
  exit 1
fi

timestamp="$(/bin/date -u +%Y%m%d-%H%M%SZ)"
source_short_head="$(/usr/bin/git -C "$ROOT_DIR" rev-parse --short HEAD)"
if [[ -z "$SNAPSHOT_NAME" ]]; then
  safe_ref="${REF//\//-}"
  SNAPSHOT_NAME="$timestamp-$MODE-$safe_ref-$source_short_head"
fi

snapshot_root="$SNAPSHOT_BASE/$SNAPSHOT_NAME"
snapshot_dir="$snapshot_root/worktree"
patch_path="$snapshot_root/current.diff"
run_ledger="$snapshot_root/runs.jsonl"
trace_dir="$snapshot_root/traces"
derived_data_dir="$snapshot_root/DerivedData"

if [[ -e "$snapshot_root" ]]; then
  echo "Error: snapshot path already exists: $snapshot_root" >&2
  exit 1
fi

/bin/mkdir -p "$snapshot_root"

echo "Creating profile snapshot:"
echo "  source: $ROOT_DIR"
echo "  mode: $MODE"
echo "  ref: $REF"
echo "  snapshot: $snapshot_dir"

/usr/bin/git -C "$ROOT_DIR" worktree add --detach "$snapshot_dir" "$REF" >/dev/null

tracked_changed="false"
untracked_count="0"
snapshot_commit=""

if [[ "$MODE" == "current" ]]; then
  /usr/bin/git -C "$ROOT_DIR" diff --binary HEAD > "$patch_path"
  if [[ -s "$patch_path" ]]; then
    /usr/bin/git -C "$snapshot_dir" apply --index "$patch_path"
    tracked_changed="true"
  fi

  untracked_count="$(copy_untracked_files "$ROOT_DIR" "$snapshot_dir")"
  /usr/bin/git -C "$snapshot_dir" add -A

  if /usr/bin/git -C "$snapshot_dir" diff --cached --quiet; then
    snapshot_commit="$(/usr/bin/git -C "$snapshot_dir" rev-parse HEAD)"
  else
    /usr/bin/git \
      -C "$snapshot_dir" \
      -c user.name="MusicFloat Snapshot" \
      -c user.email="musicfloat-snapshot@example.invalid" \
      commit -m "Temporary MusicFloat profiling snapshot" >/dev/null
    snapshot_commit="$(/usr/bin/git -C "$snapshot_dir" rev-parse HEAD)"
  fi
else
  snapshot_commit="$(/usr/bin/git -C "$snapshot_dir" rev-parse HEAD)"
fi

echo "  commit: $snapshot_commit"
echo "  tracked changes copied: $tracked_changed"
echo "  untracked files copied: $untracked_count"
echo "  isolated ledger: $run_ledger"
echo "  isolated traces: $trace_dir"
echo "  isolated DerivedData: $derived_data_dir"
echo ""

if [[ "${#COMMAND[@]}" -gt 0 ]]; then
  echo "Snapshot command:"
  print_profile_env_command "$snapshot_dir" "$run_ledger" "$trace_dir" "$derived_data_dir" "${COMMAND[@]}"
  if [[ "$RUN_COMMAND" == "true" ]]; then
    echo ""
    echo "Running command in snapshot..."
    (
      cd "$snapshot_dir"
      RUN_LEDGER="$run_ledger" \
      TRACE_DIR="$trace_dir" \
      DERIVED_DATA_DIR="$derived_data_dir" \
      "${COMMAND[@]}"
    )
  else
    echo "Add --run before -- to execute it now."
  fi
else
  echo "Suggested clean snapshot commands:"
  print_profile_env_command "$snapshot_dir" "$run_ledger" "$trace_dir" "$derived_data_dir" ./script/profile.sh sample 30s --demo --scenario overlay-karaoke
  print_profile_env_command "$snapshot_dir" "$run_ledger" "$trace_dir" "$derived_data_dir" ./script/profile.sh sample 30s --demo --apple-translation --scenario translation-enabled-overlay
  echo "For live driven profiling, run preflight first and remember it changes Music.app playback:"
  print_profile_env_command "$snapshot_dir" "$run_ledger" "$trace_dir" "$derived_data_dir" ./script/profile.sh preflight-live --drive-music
  print_profile_env_command "$snapshot_dir" "$run_ledger" "$trace_dir" "$derived_data_dir" ./script/profile.sh sample 30s --live --drive-music --scenario apple-music-driven-karaoke
fi

echo ""
echo "Snapshot remains available for inspection. Remove it later with:"
printf "git -C %q worktree remove %q\n" "$ROOT_DIR" "$snapshot_dir"
