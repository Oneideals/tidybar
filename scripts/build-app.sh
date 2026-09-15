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

CONFIG_CAP="$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}"
BIN=".build/out/Products/$CONFIG_CAP/tidybar"
[[ -f "$BIN" ]] || BIN=".build/arm64-apple-macosx/$CONFIG/tidybar"
[[ -f "$BIN" ]] || BIN=".build/x86_64-apple-macosx/$CONFIG/tidybar"
[[ -f "$BIN" ]] || { echo "找不到可执行文件，先确认 swift build 是否成功"; exit 1; }

echo "▸ 组装 $BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/tidybar"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# 优先查找本地有效的代码签名证书（如 TidyBar Development 或 Apple Development），避免重新编译后 TCC 权限重置
SIGN_IDENTITY=$(security find-identity -p codesigning -v 2>/dev/null | grep -m 1 '".*"' | sed 's/.*"\(.*\)".*/\1/' || true)
if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "▸ 使用本地证书签名: $SIGN_IDENTITY"
  codesign --force --deep --sign "$SIGN_IDENTITY" "$BUNDLE"
else
  echo "▸ ad-hoc 临时签名（本机自用；无有效证书时重新编译会导致 TCC 权限重置）"
  codesign --force --deep --sign - "$BUNDLE" 2>/dev/null \
    || echo "  签名失败：本机仍可直接运行，分发时再处理证书"
fi

# 报告 §4.3：安装包体积预算 10MB
SIZE_BYTES=$(du -sk "$BUNDLE" | awk '{print $1 * 1024}')
LIMIT_BYTES=$((10 * 1024 * 1024))
if (( SIZE_BYTES > LIMIT_BYTES )); then
  echo "  ✗ 体积 $((SIZE_BYTES / 1024 / 1024))MB 超出 10MB 预算"
  exit 1
fi
echo "  ✓ 体积 $((SIZE_BYTES / 1024))KB，在预算内"

echo "▸ 完成：open $BUNDLE"
