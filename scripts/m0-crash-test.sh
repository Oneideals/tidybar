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
echo "══════ 场景 B：拖拽中途 SIGTERM（必须走优雅收尾，而不是靠内核回收）══════"
"$BIN" --role terminate > /tmp/victim_term.log 2>&1 &
VPID=$!
# 等到拖拽真的进入按下状态再发信号：冷启动枚举要 2s 左右，固定 sleep 会打在动手之前
WAITED=0
while [ "$WAITED" -lt 125 ]; do   # 0.2s × 125 = 25s 上限
  grep -q "inflight=yes" /tmp/victim_term.log && break
  sleep 0.2
  WAITED=$((WAITED + 1))
done
kill -TERM "$VPID" 2>/dev/null
wait "$VPID" 2>/dev/null
sleep 0.6
sed 's/^/  /' /tmp/victim_term.log
"$BIN" --role inspect
if grep -q "GRACEFUL signal=15 wasInFlight=yes" /tmp/victim_term.log; then
  echo "  ✓ 收尾回调被触发，且当时确实有拖拽悬在半空"
else
  echo "  ✗ 没抓到 GRACEFUL/wasInFlight=yes，说明信号没接住或没命中拖拽窗口"; FAILS=$((FAILS+1))
fi
if grep -q "VICTIM completed\|TERMVICTIM completed" /tmp/victim_term.log; then
  echo "  ✗ 拖拽自己跑完了，本次没被打中，结论不作数"; FAILS=$((FAILS+1))
fi
RESIDUE=$("$BIN" --role inspect | grep RESIDUE)
if echo "$RESIDUE" | grep -q "commandHeld=yes"; then
  echo "  ✗ 优雅退出后 ⌘ 仍报按住"; FAILS=$((FAILS+1))
fi
if [ "$(echo "$RESIDUE" | sed -n 's/.*mouseButtons=\([0-9-]*\).*/\1/p')" != "0" ]; then
  echo "  ✗ 优雅退出后鼠标键仍报按住（半空拖拽没被抬起）"; FAILS=$((FAILS+1))
fi
if [ "$(COUNT_OF)" != "$BASELINE_COUNT" ]; then
  echo "  ✗ 图标数量在优雅退出后发生变化"; FAILS=$((FAILS+1))
fi

echo
echo "══════ 场景 C：journal 目录被破坏时不得启动失败 ══════"
mkdir -p /tmp/tidybar-corrupt/TidyBar/LayoutJournal
printf 'not json at all' > /tmp/tidybar-corrupt/TidyBar/LayoutJournal/layout.pending.json
printf '{"zones":"broken"}' > /tmp/tidybar-corrupt/TidyBar/LayoutJournal/layout.committed.json
"$BIN" --role inspect --journal /tmp/tidybar-corrupt/TidyBar/LayoutJournal | sed 's/^/  /' \
  && echo "  ✓ 损坏的 journal 未导致崩溃（读不出即视为无状态）" \
  || { echo "  ✗ 损坏 journal 导致进程失败"; FAILS=$((FAILS+1)); }

echo
echo "══════ 场景 D：永远做不成的意图，重试两次必须放弃（旧格式文件也要能读）══════"
"$BIN" --role poison | tee /tmp/poison.log | sed 's/^/  /'
if ! grep -q "readable=true" /tmp/poison.log; then
  echo "  ✗ 旧格式 pending 文件读不出来（升级会凭空丢掉用户的未完成变更）"; FAILS=$((FAILS+1))
fi
FIRST=$("$BIN" --role recover | grep "replay failed" || true)
echo "  第一次：${FIRST:-（没有失败记录，本例作废）}"
if ! echo "$FIRST" | grep -q "outcome=retryScheduled(failures: 1) pending=true"; then
  echo "  ✗ 第一次失败应保留意图并记 1 次"; FAILS=$((FAILS+1))
fi
SECOND=$("$BIN" --role recover | grep "replay failed" || true)
echo "  第二次：${SECOND:-（没有失败记录，本例作废）}"
if ! echo "$SECOND" | grep -q "outcome=abandoned pending=false"; then
  echo "  ✗ 第二次失败应放弃意图并清除 pending"; FAILS=$((FAILS+1))
fi
if "$BIN" --role inspect | grep -q "pending=local.tidybar.gone"; then
  echo "  ✗ 达到上限后意图仍留在盘上 → 每次启动都会重演"; FAILS=$((FAILS+1))
else
  echo "  ✓ 上限生效，孤儿意图已清除"
fi

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
