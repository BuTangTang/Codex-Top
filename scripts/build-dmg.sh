#!/bin/bash
set -euo pipefail

# Package the existing real universal app; this script never starts a Swift build.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ $# -gt 0 ]]; then
  printf 'Usage: [VERSION=<matching-app-version>] bash scripts/build-dmg.sh\n'
  if [[ $# -eq 1 && "$1" = "--help" ]]; then exit 0; fi
  exit 2
fi

fail() { printf 'DMG packaging failed: %s\n' "$1" >&2; exit 1; }
app_path="$repo_root/dist/Codex Top.app"
plist="$app_path/Contents/Info.plist"
[[ -d "$app_path" && -f "$plist" ]] || fail 'Build dist/Codex Top.app with --universal first.'
plutil -lint "$plist"

read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist"; }
[[ "$(read_plist CFBundleIdentifier)" = "dev.butang.codextop" ]] || fail 'Only the real Codex Top bundle can be packaged.'
[[ "$(read_plist CFBundlePackageType)" = "APPL" ]] || fail 'The bundle is not an application.'
[[ "$(read_plist CodexTopDemo)" = "false" ]] || fail 'Demo or unidentified demo configuration cannot be shared as the real app.'
[[ "$(read_plist CFBundleExecutable)" = "CodexTop" ]] || fail 'Unexpected application executable.'

bundle_version="$(read_plist CFBundleShortVersionString)"
version="${VERSION:-$bundle_version}"
[[ "$version" =~ ^[0-9A-Za-z.-]+$ ]] || fail 'The version contains unsupported filename characters.'
[[ "$version" = "$bundle_version" ]] || fail 'VERSION does not match the existing app. Rebuild that version before packaging.'
minimum_system="$(read_plist LSMinimumSystemVersion)"
[[ "$minimum_system" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail 'The app has no valid minimum macOS version.'
[[ "${minimum_system%%.*}" -ge 14 ]] || fail 'Codex Top requires macOS 14 or later.'

executable="$app_path/Contents/MacOS/CodexTop"
[[ -x "$executable" ]] || fail 'The application executable is missing or not executable.'
architectures="$(lipo -archs "$executable")"
[[ "$architectures" = "x86_64 arm64" || "$architectures" = "arm64 x86_64" ]] || fail 'A universal arm64 + x86_64 build is required.'
build_info="$(xcrun vtool -show-build "$executable")"
if ! printf '%s\n' "$build_info" | awk -v minimum="$minimum_system" '
  function newer(a, b, aa, bb, i) {
    split(a, aa, "."); split(b, bb, ".")
    for (i = 1; i <= 3; i++) {
      if (aa[i] + 0 > bb[i] + 0) return 1
      if (aa[i] + 0 < bb[i] + 0) return 0
    }
    return 0
  }
  $1 == "platform" { platforms++; if ($2 != "MACOS") invalid = 1 }
  $1 == "minos" { minima++; if (newer($2, minimum)) invalid = 1 }
  END { exit (invalid || platforms != 2 || minima != 2) }
'; then
  fail 'Both executable slices must target macOS and support the minimum version declared in Info.plist.'
fi
codesign --verify --deep --strict "$app_path"

staging_root="$(mktemp -d -t codex-top-dmg)"
cleanup() { if [[ -n "$staging_root" && -d "$staging_root" ]]; then rm -rf "$staging_root"; fi; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
payload="$staging_root/payload"
mkdir -p "$payload"
ditto "$app_path" "$payload/Codex Top.app"
codesign --verify --deep --strict "$payload/Codex Top.app"
ln -s /Applications "$payload/Applications"
printf '%s\n' \
  "Codex Top $version" \
  "支持 macOS $minimum_system 或更新版本，Apple Silicon 与 Intel。" \
  '' \
  '安装：' \
  '1. 先退出正在运行的 Codex Top。' \
  '2. 将 Codex Top.app 拖到旁边的 Applications 文件夹。' \
  '3. 从“应用程序”打开 Codex Top；在菜单栏或悬浮圆环进入设置。' \
  '4. 使用你自己已登录的 Codex 数据目录。安装包不包含任何账户或任务数据。' \
  '' \
  '若 macOS 阻止首次打开，先核对发布来源和 SHA-256，再按系统“隐私与安全性”页面提示处理。' \
  '更新时重复上述步骤；应用设置和任务选择保存在你的用户目录中。' \
  '开源协议：GNU GPL v3，协议副本包含在应用资源中。' \
  '项目：https://github.com/BuTangTang/Codex-Top' \
  > "$payload/安装说明.txt"

image_name="Codex-Top-$version-macOS.dmg"
image_path="$staging_root/$image_name"
hdiutil create -volname "Codex Top $version" -srcfolder "$payload" \
  -format UDZO -imagekey zlib-level=9 -fs HFS+ -o "$image_path"
hdiutil verify "$image_path"
(
  cd "$staging_root"
  shasum -a 256 "$image_name" > "$image_name.sha256"
)
mkdir -p "$repo_root/dist"
mv "$image_path" "$repo_root/dist/$image_name"
mv "$image_path.sha256" "$repo_root/dist/$image_name.sha256"
printf 'Packaged DMG: dist/%s\nSHA-256: dist/%s.sha256\n' "$image_name" "$image_name"
