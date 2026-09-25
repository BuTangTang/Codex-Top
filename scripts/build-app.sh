#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
configuration="${CONFIGURATION:-release}"
# 原生包与连接组件共用默认版本；显式覆盖时两步须传相同的构建参数。
version="${VERSION:-$(plutil -extract version raw -o - scripts/build-version.json)}"
build_number="${CODEX_TOP_BUILD_NUMBER:-$(plutil -extract buildNumber raw -o - scripts/build-version.json)}"
app_name="Codex Top"
bundle_id="dev.butang.codextop"
demo=false
with_connection=false
universal=false
build_args=(-c "$configuration")
for option in "$@"; do
  case "$option" in
    --demo) app_name="Codex Top Demo"; bundle_id="dev.butang.codextop.demo"; demo=true ;;
    --with-connection) with_connection=true ;;
    --universal) universal=true; build_args+=(--arch arm64 --arch x86_64) ;;
    *) printf 'Unknown option: %s\n' "$option" >&2; exit 2 ;;
  esac
done
# 连接组件当前只按本机构建，不能把单架构组件宣称为通用安装包。
if [[ "$with_connection" == true && "$universal" == true ]]; then
  printf 'Universal connection packages require a verified component for both architectures.\n' >&2; exit 2
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ || ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  printf 'Use a semantic VERSION and a positive CODEX_TOP_BUILD_NUMBER.\n' >&2; exit 2
fi
# 在覆盖已有构建目录前拒绝陈旧组件，避免 native build 与后台运行版本脱节。
if [[ "$with_connection" == true ]]; then
  connection_payload="$repo_root/.local/connection-payload"
  if [[ ! -x "$connection_payload/codex-top-bridge" ]]; then
    printf 'Build the connection component with scripts/build-connection.mjs first.\n' >&2; exit 1
  fi
  component_version="$(plutil -extract buildVersion raw -o - "$connection_payload/package-dist/.build-manifest.json" 2>/dev/null)" || {
    printf 'The connection component has no verified build version. Rebuild it first.\n' >&2; exit 1
  }
  if [[ "$component_version" != "$version+codextop.$build_number" ]]; then
    printf 'The connection component does not match this app version/build. Rebuild it first.\n' >&2; exit 1
  fi
fi
swift build "${build_args[@]}"
bin_path="$(swift build "${build_args[@]}" --show-bin-path)"
app_path="$repo_root/dist/$app_name.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
install -m 755 "$bin_path/CodexTop" "$app_path/Contents/MacOS/CodexTop"
install -m 644 LICENSE "$app_path/Contents/Resources/LICENSE"
# 手机连接版从已验证的托管 payload 装入组件，不依赖用户安装 Node 或包管理器。
if [[ "$with_connection" == true ]]; then
  mkdir -p "$app_path/Contents/Resources/connection"
  # payload 的唯一生产者会重建目录；打包时完整复制，避免混用上一批依赖。
  rsync -a --delete "$connection_payload/" "$app_path/Contents/Resources/connection/"
else
  # 这里只清理本脚本拥有的构建目录，避免普通包夹带上一次的连接组件。
  rm -rf "$app_path/Contents/Resources/connection"
fi
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
<key>CFBundleVersion</key><string>$build_number</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 BuTangTang. GNU GPL v3.</string>
<key>CodexTopDemo</key><$demo/>
</dict></plist>
PLIST
# 自用发布可提供默认服务地址；开源构建不内置部署地址，已有用户配置始终优先。
if [[ -n "${CODEX_TOP_DEFAULT_SERVER_URL:-}" ]]; then
  plutil -insert CodexTopConnectionServer -string "$CODEX_TOP_DEFAULT_SERVER_URL" "$app_path/Contents/Info.plist"
fi
plutil -lint "$app_path/Contents/Info.plist"
codesign --force --sign "${SIGN_IDENTITY:--}" --timestamp=none "$app_path"
codesign --verify --strict "$app_path"
printf 'Built: %s\n' "$app_path"
