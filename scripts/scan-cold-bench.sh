#!/usr/bin/env bash
# 冷启动扫描 A/B：每个配置都在**全新进程**里跑第一次枚举。
# 为什么不能在同一进程里比：第二次扫描已经是热的（真机实测热扫 40~200ms，冷扫 1.3~4.1s），
# 拿热扫数字汇报"启动到接管"等于自欺。
# 用法：./scripts/scan-cold-bench.sh [每个配置的轮数]
set -uo pipefail
cd "$(dirname "$0")/.."

ROUNDS="${1:-3}"
BIN=".build/debug/tidybar-probe"

if [ ! -x "$BIN" ]; then
  echo "先构建：swift build"
  exit 1
fi

CONFIGS=(
  "1 -1"
  "1 500"
  "6 -1"
  "6 500"
  "6 150"
  "12 500"
)

echo "配置(并发 超时ms)  每轮：图标数/进程数/首扫ms"
for config in "${CONFIGS[@]}"; do
  read -r CONC TIMEOUT <<< "${config}"
  LINE=""
  ICONS=()
  for _ in $(seq 1 "$ROUNDS"); do
    OUT=$("$BIN" --first-only --concurrency "$CONC" --timeout "$TIMEOUT" 2>/dev/null | tail -1)
    ICON=$(echo "$OUT" | sed -n 's/.*icons=\([0-9]*\).*/\1/p')
    PROC=$(echo "$OUT" | sed -n 's/.*processes=\([0-9]*\).*/\1/p')
    MS=$(echo "$OUT" | sed -n 's/.*ms=\([0-9]*\).*/\1/p')
    ICONS+=("$ICON")
    LINE="${LINE} ${ICON}/${PROC}/${MS}ms"
  done
  # 覆盖率用最小值判断：一次少 8 个图标就是不可接受，平均值会把它抹平
  LOW=$(printf '%s\n' "${ICONS[@]}" | sort -n | head -1)
  printf 'c=%-3s t=%-5s 最低图标=%-4s %s\n' "$CONC" "$TIMEOUT" "$LOW" "$LINE"
done
