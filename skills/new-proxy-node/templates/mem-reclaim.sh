#!/bin/sh
# 小容器 page-cache 回收（128M / 192M 限额的 NAT 小鸡）
#
# 为什么需要：sing-box(92MB) + cloudflared(40MB) 二进制被执行后，页缓存会长期
# 把 cgroup memory.current 顶到 99%（面板就显示「内存满」）。真实占用（anon）只有 ~27MB，
# PSI 也是 0，但数字贴顶会让平台面板/告警一直紧张，个别平台还会按这个口径处理容器。
# 本脚本每 15 分钟回收一次，把数字压回 40-80MB 区间；cache 会按需重新读盘，无副作用。
#
# 安装：/usr/local/bin/mem-reclaim.sh（755）+ /etc/init.d/mem-reclaim（见同目录 .openrc 模板）
# 力度（2026-10-13 调过）：一次最多回收 30MB，而且必须留够 20MB 文件缓存
# ——否则 reclaim 目标大于可回收的 file cache 时会去挤 anon，把进程内存换到 swap
# （实测：连写 6×20M 后 memory.swap.current 涨到 22-25MB）。只回收文件缓存没这问题。
LOG=/var/log/mem-reclaim.log
INTERVAL=900
MAX_TARGET=30000000      # 单次回收上限 30MB
KEEP_FILE=20000000       # 至少保留 20MB 文件缓存
HIGH_PCT=60              # 低于限额 60% 就不动手

while :; do
  sleep "$INTERVAL"
  CUR=$(cat /sys/fs/cgroup/memory.current)
  MAX=$(cat /sys/fs/cgroup/memory.max)
  FILE=$(awk '/^file /{print $2}' /sys/fs/cgroup/memory.stat)
  TARGET=0
  if [ -n "$MAX" ] && [ "$MAX" != "max" ] && [ "$CUR" -gt "$(( MAX * HIGH_PCT / 100 ))" ]; then
    TARGET=$(( FILE - KEEP_FILE ))
    [ "$TARGET" -gt "$MAX_TARGET" ] && TARGET=$MAX_TARGET
  fi
  if [ "$TARGET" -gt 0 ]; then
    echo "$TARGET" > /sys/fs/cgroup/memory.reclaim 2>/dev/null || TARGET=0
  fi
  ANON=$(awk '/^anon /{print $2}' /sys/fs/cgroup/memory.stat)
  SWAP=$(cat /sys/fs/cgroup/memory.swap.current 2>/dev/null || echo n/a)
  echo "$(date '+%Y-%m-%d %H:%M:%S') reclaimed=$TARGET current=$(cat /sys/fs/cgroup/memory.current) anon=$ANON file=$(awk '/^file /{print $2}' /sys/fs/cgroup/memory.stat) swap=$SWAP" >> "$LOG"
  if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 200 ]; then
    tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
done
