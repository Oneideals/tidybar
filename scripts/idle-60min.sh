#!/usr/bin/env bash
# 真机静置 1 小时：内存/线程/CPU 时间是否增长（M0 验证项 4 欠的账）。
# 只观测，不重启被测进程；Energy 评级需要活动监视器的 GUI 读数，脚本拿不到，
# 所以这里用「1 小时内累计 CPU 秒数」作为功耗的间接代理，并如实标注它不等于系统能耗评级。
set -uo pipefail

MINUTES="${1:-60}"
PID="${2:-}"

if [ -z "$PID" ]; then
  PID=$(pgrep -x tidybar | head -1)
fi
if [ -z "$PID" ]; then
  echo "找不到 tidybar 进程，先跑：./scripts/build-app.sh && ./dist/TidyBar.app/Contents/MacOS/tidybar &"
  exit 1
fi

footprint_mb() {
  # footprint 只给整数 MB（"phys_footprint: 13 MB"）。别去乘 1048576——
  # 上一版把它当字节解析，结果读出 0.0MB，一整轮观测白跑。
  footprint -p "$1" 2>/dev/null | awk '/phys_footprint:/ {print $2; exit}'
}

cpu_seconds() {
  # ps 的 time 形如 00:00.15，换算成秒
  ps -o time= -p "$1" | tr -d ' ' | awk -F'[:.]' '{
    if (NF==3) printf "%d", ($1*60+$2)+$3/100;
    else if (NF==2) printf "%d", $1+$2/100;
    else print 0 }'
}

thread_count() { ps -M -p "$1" 2>/dev/null | tail -n +2 | wc -l | tr -d ' '; }

echo "静置观测开始｜pid=${PID}｜时长 ${MINUTES} 分钟"
F0=$(footprint_mb "$PID"); C0=$(cpu_seconds "$PID"); T0=$(thread_count "$PID")
L0=$(wc -l < /tmp/idle.err 2>/dev/null | tr -d ' ')
echo "t0  phys_footprint=${F0}MB cpu=${C0}s threads=${T0} logLines=${L0}"

sleep $((MINUTES * 60))

if ! ps -p "$PID" >/dev/null 2>&1; then
  echo "✗ 观测期间进程消失，本次结论作废"
  exit 1
fi
F1=$(footprint_mb "$PID"); C1=$(cpu_seconds "$PID"); T1=$(thread_count "$PID")
L1=$(wc -l < /tmp/idle.err 2>/dev/null | tr -d ' ')
CPU_DELTA=$((C1 - C0))
ELAPSED=$((MINUTES * 60))
PERCENT=$(awk -v d="$CPU_DELTA" -v e="$ELAPSED" 'BEGIN{printf "%.3f", d*100/e}')

echo "t1  phys_footprint=${F1}MB cpu=${C1}s threads=${T1} logLines=${L1}"
echo "──────── 结论 ────────"
echo "内存  ${F0}MB → ${F1}MB（增长 $(awk -v a="$F0" -v b="$F1" 'BEGIN{printf "%d", b-a}')MB，预算 40MB；footprint 粒度为 1MB）"
echo "线程  ${T0} → ${T1}（单位数为健康）"
echo "CPU   ${MINUTES} 分钟累计 ${CPU_DELTA}s ⇒ 平均占用 ${PERCENT}%（预算 0.1%）"
echo "日志  新增 $((L1 - L0)) 行（静置期不该有持续输出，那说明退化成轮询）"
echo "Energy 评级：本脚本拿不到，需在活动监视器→能耗 面板目测；CPU 占用只是间接代理"
