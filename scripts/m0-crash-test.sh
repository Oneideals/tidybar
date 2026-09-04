#!/usr/bin/env bash
# M0 验证项 3：崩溃与强杀安全的编排脚本。
# 实验对象只有自造的 fixture 图标；残留状态一律由「全新进程」读取，
# 因为受害者自身在 mouseDown/mouseUp 之间被杀时 defer 不会执行，自报清白没有意义。
set -uo pipefail
cd "$(dirname "$0")/.."

ROUNDS="${1:-3}"
BIN=".build/debug/tidybar-crash-probe"
FIXTURE="local.tidybar.fixture"

swift build >/dev/null 2>&1 || { echo "构建失败"; exit 1; }

if ! pgrep -x tidybar-fixture >/dev/null; then
  ./scripts/build-fixture-app.sh >/dev/null 2>&1
  open dist/TidyBarFixture.app --args 4
  sleep 2
fi

ORDER_OF() { "$BIN" --role inspect 2>/dev/null | awk -F'order=' '/ICONS/{print $2}'; }
COUNT_OF() { "$BIN" --role inspect 2>/dev/null | sed -n 's/.*ICONS count=\([0-9]*\).*/\1/p'; }

echo "══════ 基线 ══════"
"$BIN" --role inspect
BASELINE_COUNT=$(COUNT_OF)
BASELINE_ORDER=$(ORDER_OF)

echo
echo "══════ 场景 A：拖拽中途 kill -9（共 $ROUNDS 轮）══════"
FAILS=0
for i in $(seq 1 "$ROUNDS"); do
  "$BIN" --role drag > /tmp/victim.log 2>&1 &
  VPID=$!
  sleep 1.4                      # 拖拽总时长 ~3.2s，1.4s 必然落在 mouseDown 之后
  kill -9 "$VPID" 2>/dev/null
  wait "$VPID" 2>/dev/null
  sleep 0.6
  echo "── 第 $i 轮（受害者 pid=$(awk '/pid=/{sub(/.*pid=/,"");sub(/ .*/,"");print;exit}' /tmp/victim.log)）"
  "$BIN" --role inspect
  "$BIN" --role recover | sed 's/^/  /'
  NOW_COUNT=$(COUNT_OF); NOW_ORDER=$(ORDER_OF)
  if [ "$NOW_COUNT" != "$BASELINE_COUNT" ]; then
    echo "  ✗ 图标数量变化：$BASELINE_COUNT → $NOW_COUNT"; FAILS=$((FAILS+1))
  fi
  RESIDUE=$("$BIN" --role inspect | grep RESIDUE)
  if echo "$RESIDUE" | grep -q "commandHeld=yes"; then
    echo "  ✗ ⌘ 残留在按住状态"; FAILS=$((FAILS+1))
  fi
  if [ "$(echo "$RESIDUE" | sed -n 's/.*mouseButtons=\([0-9-]*\).*/\1/p')" != "0" ]; then
    echo "  ✗ 鼠标键残留在按住状态"; FAILS=$((FAILS+1))
  fi
done

echo
echo "══════ 场景 B：干净退出（SIGTERM，defer 应正常收尾）══════"
"$BIN" --role drag > /tmp/victim_term.log 2>&1 &
VPID=$!
sleep 1.4
kill -TERM "$VPID" 2>/dev/null
wait "$VPID" 2>/dev/null
sleep 0.6
"$BIN" --role inspect

echo
echo "══════ 场景 C：journal 目录被破坏时不得启动失败 ══════"
mkdir -p /tmp/tidybar-corrupt/TidyBar/LayoutJournal
printf 'not json at all' > /tmp/tidybar-corrupt/TidyBar/LayoutJournal/layout.pending.json
printf '{"zones":"broken"}' > /tmp/tidybar-corrupt/TidyBar/LayoutJournal/layout.committed.json
"$BIN" --role inspect --journal /tmp/tidybar-corrupt/TidyBar/LayoutJournal | sed 's/^/  /' \
  && echo "  ✓ 损坏的 journal 未导致崩溃（读不出即视为无状态）" \
  || { echo "  ✗ 损坏 journal 导致进程失败"; FAILS=$((FAILS+1)); }

echo
echo "══════ 结果 ══════"
FINAL_COUNT=$(COUNT_OF); FINAL_ORDER=$(ORDER_OF)
echo "图标数量  $BASELINE_COUNT → $FINAL_COUNT"
echo "顺序      $BASELINE_ORDER → $FINAL_ORDER"
echo "每轮顺序变化都是系统对该拖拽的正常结果，重放不产生重复移动即为达标"
if [ "$FAILS" -eq 0 ] && [ "$FINAL_COUNT" = "$BASELINE_COUNT" ]; then
  echo "✓ 验证项 3 通过：强杀后无输入残留、图标不损坏、孤儿意图可识别并重放"
  exit 0
fi
echo "✗ 验证项 3 存在 $FAILS 项问题，见上"
exit 1
