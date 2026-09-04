#!/usr/bin/env bash
# 组装可在 Finder 里双击运行的 TidyBar.app（无需 Xcode 工程）。
# 产物：dist/TidyBar.app
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="TidyBar"
DIST="dist"
BUNDLE="$DIST/$APP_NAME.app"
CONFIG="${1:-release}"

echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN=".build/arm64-apple-macosx/$CONFIG/tidybar"
[[ -f "$BIN" ]] || BIN=".build/x86_64-apple-macosx/$CONFIG/tidybar"
[[ -f "$BIN" ]] || { echo "找不到可执行文件，先确认 swift build 是否成功"; exit 1; }

echo "▸ 组装 $BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/tidybar"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

echo "▸ ad-hoc 签名（本机自用；分发需换 Developer ID 并公证）"
codesign --force --deep --sign - "$BUNDLE" 2>/dev/null \
  || echo "  签名失败：本机仍可直接运行，分发时再处理证书"

# 报告 §4.3：安装包体积预算 10MB
SIZE_BYTES=$(du -sk "$BUNDLE" | awk '{print $1 * 1024}')
LIMIT_BYTES=$((10 * 1024 * 1024))
if (( SIZE_BYTES > LIMIT_BYTES )); then
  echo "  ✗ 体积 $((SIZE_BYTES / 1024 / 1024))MB 超出 10MB 预算"
  exit 1
fi
echo "  ✓ 体积 $((SIZE_BYTES / 1024))KB，在预算内"

echo "▸ 完成：open $BUNDLE"
