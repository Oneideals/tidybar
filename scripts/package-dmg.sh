#!/usr/bin/env bash
# 制作便携、可直接对外分发的 TidyBar 安装 DMG 镜像
# 产物：dist/TidyBar-v<version>.dmg 及配对的 sha256 校验文件
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"

echo "▸ 1. 编译并组装 TidyBar.app ($CONFIG)..."
./scripts/build-app.sh "$CONFIG"

APP_PATH="dist/TidyBar.app"
[[ -d "$APP_PATH" ]] || { echo "❌ 找不到 $APP_PATH"; exit 1; }

VERSION=$(defaults read "$(pwd)/$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "0.1.0")
DMG_NAME="TidyBar-v${VERSION}"
DMG_FINAL="dist/${DMG_NAME}.dmg"
DMG_STAGE="dist/dmg_stage"

echo "▸ 2. 准备 DMG 挂载根目录 (${DMG_STAGE})..."
rm -rf "$DMG_STAGE" "$DMG_FINAL" "${DMG_FINAL}.sha256"
mkdir -p "$DMG_STAGE"

cp -R "$APP_PATH" "$DMG_STAGE/TidyBar.app"
ln -s /Applications "$DMG_STAGE/Applications"

# 若存在开源协议和隐私说明，一并放入 DMG 便于离线查阅
if [[ -f LICENSE ]]; then
  cp LICENSE "$DMG_STAGE/LICENSE.txt"
fi
if [[ -f PRIVACY.md ]]; then
  cp PRIVACY.md "$DMG_STAGE/PRIVACY.txt"
fi

echo "▸ 3. 生成高压缩只读 DMG (${DMG_FINAL})..."
hdiutil create \
  -volname "TidyBar" \
  -srcfolder "$DMG_STAGE" \
  -ov \
  -format UDZO \
  "$DMG_FINAL"

rm -rf "$DMG_STAGE"

echo "▸ 4. 计算 SHA256 校验和..."
shasum -a 256 "$DMG_FINAL" > "${DMG_FINAL}.sha256"

DMG_SIZE=$(du -sh "$DMG_FINAL" | awk '{print $1}')
SHA256=$(cat "${DMG_FINAL}.sha256" | awk '{print $1}')

echo "=========================================="
echo "✅ DMG 打包完成: $DMG_FINAL ($DMG_SIZE)"
echo "   SHA256: $SHA256"
echo "=========================================="
