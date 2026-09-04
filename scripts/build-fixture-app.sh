#!/usr/bin/env bash
# M0 实验品打包：造一个有自己的 bundle id、能发布 AXExtrasMenuBar 的最小 App。
# 为什么非要打包：M0 验证项 1 实测——无 bundle 的 CLI 进程不发布 AXExtrasMenuBar，
# 在它身上做拖拽实验只会得出「机制不工作」的假结论。
# 用法：./scripts/build-fixture-app.sh && open dist/TidyBarFixture.app --args 4
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/TidyBarFixture.app"
echo "▸ swift build -c release --product tidybar-fixture"
swift build -c release --product tidybar-fixture

BIN=$(find .build -name tidybar-fixture -type f -perm +111 | head -1)
[[ -n "$BIN" ]] || { echo "找不到 tidybar-fixture 产物"; exit 1; }

echo "▸ 组装 $APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/tidybar-fixture"
cp Resources/Fixture-Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" 2>/dev/null || echo "  （ad-hoc 签名失败，本机仍可运行）"

echo "▸ 完成。启动 4 个实验图标："
echo "    open $APP --args 4"
echo "  验证完记得关掉它："
echo "    pkill -x tidybar-fixture"
