#!/usr/bin/env bash
# bump_build.sh — increment CURRENT_PROJECT_VERSION in MusicFloat.xcodeproj
# Run post-merge on main to auto-increment the build number.
# MARKETING_VERSION is NOT touched — that's a manual/agent decision for tags.
set -euo pipefail

PROJECT_FILE="MusicFloat.xcodeproj/project.pbxproj"

current_build=$(grep -m1 "CURRENT_PROJECT_VERSION =" "$PROJECT_FILE" | sed 's/.*= //' | sed 's/;//')
new_build=$((current_build + 1))

echo "Build number: $current_build → $new_build"

# Replace using sed (all occurrences, same pattern in all targets)
sed -i '' "s/CURRENT_PROJECT_VERSION = $current_build;/CURRENT_PROJECT_VERSION = $new_build;/g" "$PROJECT_FILE"

echo "Done. Run: git add $PROJECT_FILE && git commit -m 'Bump build to $new_build'"
