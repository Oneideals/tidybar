#!/usr/bin/env bash
# 对照 docs/软件开发计划.md §4.3 的预算，实测一次常驻内存与空闲 CPU。
# 用法：./scripts/perf-check.sh [--minutes 5]
set -euo pipefail

cd "$(dirname "$0")/.."

MINUTES=5
while [[ $# -gt 0 ]]; do
  case "$1" in
    --minutes) MINUTES="$2"; shift 2 ;;
    *) echo "未知参数 $1"; exit 2 ;;
  esac
done

LIMIT_MEM_MB=40          # PerformanceBudget.maxResidentMemoryBytes
LIMIT_CPU_PERCENT=0.1    # PerformanceBudget.maxIdleCPUPercent
ICON_COUNT=${ICON_COUNT:-20}

if [[ ! -d dist/TidyBar.app ]]; then
  echo "▸ 先构建 .app"
  ./scripts/build-app.sh
fi

echo "▸ 启动 TidyBar（静置 ${MINUTES} 分钟，模拟 $ICON_COUNT 图标场景请自行保持日常 App 在菜单栏）"
open dist/TidyBar.app
sleep 3

PID=$(pgrep -x tidybar | head -1 || true)
if [[ -z "$PID" ]]; then
  echo "✗ 没找到 tidybar 进程，检查是否能正常启动"
  exit 1
fi

SECONDS=$((MINUTES * 60))
echo "  进程 PID=$PID，开始计时…"
sleep "$SECONDS"

MEM_KB=$(ps -o rss= -p "$PID" | tr -d ' ')
CPU=$(ps -o %cpu= -p "$PID" | tr -d ' ')
RSS_MB=$((MEM_KB / 1024))

# 判定口径：phys_footprint（与 PerformanceBudget.maxResidentMemoryBytes 一致）。
# ps 的 RSS 含 AppKit 共享页，菜单栏工具会虚高 2~3 倍，只作参考打印。
FOOTPRINT_MB=""
if command -v footprint >/dev/null 2>&1; then
  FOOTPRINT_MB=$(footprint -p "$PID" 2>/dev/null | awk '/phys_footprint:/ {gsub(/[^0-9]/,"",$2); print $2; exit}' || true)
fi

echo "▸ 实测：phys_footprint ${FOOTPRINT_MB:-未知}MB ｜ ps RSS ${RSS_MB}MB（参考）｜ CPU ${CPU}%"

STATUS=0
if [[ -z "$FOOTPRINT_MB" ]]; then
  echo "  ！取不到 phys_footprint，退化用 RSS 判定（会偏严），请确认 footprint 可用"
  JUDGED_MB=$RSS_MB
else
  JUDGED_MB=$FOOTPRINT_MB
fi

if (( JUDGED_MB > LIMIT_MEM_MB )); then
  echo "  ✗ 内存超预算（${JUDGED_MB}MB > ${LIMIT_MEM_MB}MB）"
  STATUS=1
else
  echo "  ✓ 内存达标（${JUDGED_MB}MB <= ${LIMIT_MEM_MB}MB）"
fi

CPU_OK=$(awk -v c="$CPU" -v l="$LIMIT_CPU_PERCENT" 'BEGIN { print (c + 0 <= l + 0) ? 1 : 0 }')
if [[ "$CPU_OK" == "1" ]]; then
  echo "  ✓ 空闲 CPU 达标（<= ${LIMIT_CPU_PERCENT}%）"
else
  echo "  ✗ 空闲 CPU 超标（> ${LIMIT_CPU_PERCENT}%）：先查是否退化成高频轮询"
  STATUS=1
fi

echo "▸ 结束，退出被测进程"
kill "$PID" 2>/dev/null || true
exit "$STATUS"
