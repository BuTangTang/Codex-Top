#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
swift test
bash scripts/build-app.sh "$@"
version="${VERSION:-0.1.0-dev}"
app_name="Codex Top"
for option in "$@"; do if [ "$option" = "--demo" ]; then app_name="Codex Top Demo"; fi; done
archive="dist/${app_name// /-}-$version-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "dist/$app_name.app" "$archive"
shasum -a 256 "$archive" > "$archive.sha256"
printf 'Packaged: %s\n' "$archive"
