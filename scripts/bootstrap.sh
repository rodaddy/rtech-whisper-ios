#!/usr/bin/env bash
# Regenerates RtechWhisper.xcodeproj from project.yml, which is the source of
# truth. The project is gitignored, so run this after a fresh clone and after
# any change to project.yml.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is not installed. Install it with: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate

cat <<'EOF'

Generated RtechWhisper.xcodeproj.

Next:
  1. swift test --package-path Packages/RtechWhisperKit   # the kit's tests
  2. open RtechWhisper.xcodeproj, set your team, and run on a device
EOF
