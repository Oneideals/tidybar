#!/usr/bin/env bash
# 空闲 CPU 终版测量：**无输入静置**口径（品类通行测法）。
#
# 为什么改口径：预算"空闲 0.1%"指的应当是"没人碰电脑时"；人在正常使用时，
# 前台 App 切换触发 NSWorkspace 重扫属于功能行为，把它算进"空闲"是口径错误
# ——上一轮 0.292% 里就混着这种流量。HIDIdleTime 由系统维护（最后一次键鼠输入至今的纳秒数），
# 本脚本只把 **idle 持续 ≥30s 的区间** 内累积的 CPU 计入预算判定；idle 中断（用户动了）之后的
# CPU 记为"使用期"，只报告不判定。
set -uo pipefail
cd "$(dirname "$0")/.."

MINUTES="${1:-40}"
PID="${2:-}"
IDLE_THRESHOLD_NS=$((30 * 1000000000))   # 30s 无输入才算静置

if [ -z "$PID" ]; then
  PID=$(pgrep -x tidybar | head -1)
fi
if [ -z "$PID" ]; then
  echo "找不到 tidybar 进程"
  exit 1
fi

cpu_seconds() {
  ps -o time= -p "$1" | tr -d ' ' | awk -F'[:.]' '{
    if (NF==3) printf "%d", ($1*60+$2)+$3/100;
    else if (NF==2) printf "%d", $1+$2/100;
    else print 0 }'
}

hid_idle_ns() {
  ioreg -c IOHIDSystem -d 1 2>/dev/null | sed -n 's/.*"HIDIdleTime" = \([0-9]*\).*/\1/p' | head -1
}

footprint_mb() {
  footprint -p "$1" 2>/dev/null | awk '/phys_footprint:/ {print $2; exit}'
}

echo "静置观测（无输入口径）｜pid=$PID｜时长 ${MINUTES} 分钟｜判定区间：无键鼠输入 ≥30s"

CPU0=$(cpu_seconds "$PID")
F0=$(footprint_mb "$PID")
IDLE0=$(hid_idle_ns)
echo "t0  phys_footprint=${F0}MB cpu=${CPU0}s"

# 每 2s 采样一次：记录 (idle_seconds, cpu_seconds) 对
SAMPLES="/tmp/idle-samples-$$.txt"
: > "$SAMPLES"
ELAPSED=0
while [ "$ELAPSED" -lt $((MINUTES * 60)) ]; do
  sleep 2
  ELAPSED=$((ELAPSED + 2))
  IDLE=$(hid_idle_ns); CPU=$(cpu_seconds "$PID")
  echo "$IDLE $CPU" >> "$SAMPLES"
done

CPU1=$(cpu_seconds "$PID")
F1=$(footprint_mb "$PID")

# 逐段归因：段长 2s。段的"期初 idle"≥30s 且"期末 idle"≥ 段长 ⇒ 整段无人输入。
# idle 期间 CPU 增量 = 该段 CPU 增量；使用期同理累加，分开报。
python3 - "$SAMPLES" "$CPU0" "$IDLE0" <<'PY'
import sys

samples = []
for line in open(sys.argv[1]):
    idle_ns, cpu = line.split()
    samples.append((int(idle_ns), float(cpu)))
cpu0 = float(sys.argv[2])
idle0 = int(sys.argv[3])

SEGMENT = 2.0
IDLE_MIN_NS = 30 * 1_000_000_000

idle_cpu = used_cpu = 0.0
idle_secs = used_secs = 0.0
prev_cpu, prev_idle = cpu0, idle0
for idle_ns, cpu in samples:
    d_cpu = max(0.0, cpu - prev_cpu)
    was_idle = prev_idle >= IDLE_MIN_NS and idle_ns >= SEGMENT * 1e9
    if was_idle:
        idle_cpu += d_cpu; idle_secs += SEGMENT
    else:
        used_cpu += d_cpu; used_secs += SEGMENT
    prev_cpu, prev_idle = cpu, idle_ns

total = idle_secs + used_secs
print(f"t1  无输入时长 {idle_secs/60:.1f} 分钟 / 使用中 {used_secs/60:.1f} 分钟（共 {total/60:.1f}）")
if idle_secs > 0:
    pct = idle_cpu * 100 / idle_secs
    print(f"──────── 结论 ────────")
    print(f"无输入期间 CPU 累计 {idle_cpu:.0f}s ⇒ 平均 {pct:.3f}%（预算 0.1%）")
    verdict = "✓" if pct <= 0.1 else "✗"
    print(f"{verdict} 空闲预算{'达标' if pct <= 0.1 else '未达标'}")
else:
    print("本段没有持续 ≥30s 的无输入区间，无法判定（测量期间请别动鼠标键盘）")
print(f"使用期间 CPU 累计 {used_cpu:.0f}s（功能行为：前台切换触发重扫等，不参与预算判定）")
PY

rm -f "$SAMPLES"
echo "内存  ${F0}MB → ${F1}MB（footprint 粒度 1MB）"
