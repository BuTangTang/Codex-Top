#!/bin/bash
set -euo pipefail

# 只构建独立合成窗口；输出放入项目忽略目录，不覆盖正式应用或安装包。
fixture_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$fixture_dir/../.." && pwd)"
app_dir="$repo_dir/.local/goal-edit-workflow/GoalEditFixture.app"
swift build --package-path "$fixture_dir" -c release
binary_dir="$(swift build --package-path "$fixture_dir" -c release --show-bin-path)"
mkdir -p "$app_dir/Contents/MacOS"
cp "$binary_dir/GoalEditFixture" "$app_dir/Contents/MacOS/GoalEditFixture"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.butang.codextop.goaledittest</string>
<key>CFBundleName</key><string>目标操作验证</string>
<key>CFBundleDisplayName</key><string>目标操作验证</string>
<key>CFBundleExecutable</key><string>GoalEditFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
printf '%s\n' "$app_dir"
