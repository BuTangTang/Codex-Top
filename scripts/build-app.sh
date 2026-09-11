#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
configuration="${CONFIGURATION:-release}"
version="${VERSION:-0.1.0}"
app_name="Codex Top"
bundle_id="dev.butang.codextop"
demo=false
build_args=(-c "$configuration")
for option in "$@"; do
  case "$option" in
    --demo) app_name="Codex Top Demo"; bundle_id="dev.butang.codextop.demo"; demo=true ;;
    --universal) build_args+=(--arch arm64 --arch x86_64) ;;
    *) printf 'Unknown option: %s\n' "$option" >&2; exit 2 ;;
  esac
done
if [[ ! "$version" =~ ^[0-9A-Za-z.-]+$ ]]; then
  printf 'VERSION must contain only letters, numbers, dots or hyphens.\n' >&2; exit 2
fi
swift build "${build_args[@]}"
bin_path="$(swift build "${build_args[@]}" --show-bin-path)"
app_path="$repo_root/dist/$app_name.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
install -m 755 "$bin_path/CodexTop" "$app_path/Contents/MacOS/CodexTop"
install -m 644 LICENSE "$app_path/Contents/Resources/LICENSE"
icon_work="$(mktemp -d "$repo_root/dist/.app-icon.XXXXXX")"
trap 'rm -rf "$icon_work"' EXIT
iconset="$icon_work/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -s format png -z "$size" "$size" "$repo_root/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" > /dev/null
  double_size=$((size * 2))
  sips -s format png -z "$double_size" "$double_size" "$repo_root/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$iconset" -o "$app_path/Contents/Resources/AppIcon.icns"
cat > "$app_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$app_name</string>
<key>CFBundleDisplayName</key><string>$app_name</string>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleExecutable</key><string>CodexTop</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 BuTangTang. GNU GPL v3.</string>
<key>CodexTopDemo</key><$demo/>
</dict></plist>
PLIST
plutil -lint "$app_path/Contents/Info.plist"
codesign --force --sign "${SIGN_IDENTITY:--}" --timestamp=none "$app_path"
codesign --verify --strict "$app_path"
printf 'Built: %s\n' "$app_path"
