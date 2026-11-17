#!/usr/bin/env bash
# udp-check.sh — UDP 入站可达性探测（NoPorts 计数法）
#
# 用途：新节点上架第一步的「鸡主/平台放不放 UDP」实测——比问鸡主更可靠，比 nc 可信
#      （家宽 OpenClash TPROXY 下本机 nc/`/dev/tcp` 对任意境外 IP:端口都假 OPEN）。
#
# 原理：从外部（vantage）发 N 个 UDP 包，节点侧内核 **InDatagrams** 精确 +N
#      即证明「面板 UDP 映射 + 入站通路」都通（有无监听都成立）。
#      辅助看 NoPorts：无监听时它会 +N；有监听时不涨（包被 socket 收走）。
#      前提：节点容器平时没有其它 UDP 流量（我们的 NAT 容器都满足；如有噪声就多发一轮）。
#
# 用法：./udp-check.sh <节点ssh别名> <节点公网IP> <UDP端口> [发包数] [发送方ssh别名]
#   ./udp-check.sh node-a <公网IP> 44504 5 <发送方ssh别名>
#
# 退出码：0 = 可达；1 = 未到达/不可判定（先回面板核对映射，再问鸡主）
set -euo pipefail

usage() {
  echo "用法: $0 <节点ssh别名> <节点公网IP> <UDP端口> [发包数=5] <发送方ssh别名>" >&2
  exit 2
}

NODE=${1:-}; IP=${2:-}; PORT=${3:-}; COUNT=${4:-5}; SENDER=${5:-}
[ -n "$SENDER" ] || { echo "错误: 需要第 5 个参数——发送方 ssh 别名（一台能向外发包的机器）" >&2; exit 2; }
[ -n "$NODE" ] && [ -n "$IP" ] && [ -n "$PORT" ] || usage

# 输出：<InDatagrams> <NoPorts>（只认数字行，避开表头行）
read_udp_stats() {
  ssh -o ConnectTimeout=8 "$NODE" \
    "awk '/^Udp:/ && \$2 ~ /^[0-9]+\$/ {print \$2, \$3}' /proc/net/snmp"
}

echo "== UDP 入站探测: ${NODE}  ${IP}:${PORT} (发包 ${COUNT} 个, 发送方 ${SENDER}) =="

LISTEN=$(ssh -o ConnectTimeout=8 "$NODE" "ss -uln 2>/dev/null | awk 'NR>1{print \$4}' | grep -c ':${PORT}\$' || true")
if [ "${LISTEN:-0}" != "0" ]; then
  echo "提示: 节点上已有进程监听 UDP ${PORT}——以 InDatagrams 为准（NoPorts 不涨属正常）。"
fi

read BEFORE_IN BEFORE_NP <<<"$(read_udp_stats)"
if [ -z "${BEFORE_IN:-}" ] || [ -z "${BEFORE_NP:-}" ]; then
  echo "错误: 读不到 ${NODE} 的 UDP 计数（ssh 不通？）。先确认 ssh ${NODE} 可用再试。" >&2
  exit 2
fi
echo "发包前 InDatagrams=${BEFORE_IN}  NoPorts=${BEFORE_NP}"

ssh -o ConnectTimeout=8 "$SENDER" "python3 - ${IP} ${PORT} ${COUNT}" <<'PY'
import socket, sys
ip, port, n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for i in range(n):
    s.sendto(b"udp-probe-%d" % i, (ip, port))
s.close()
print("sent:", n)
PY

sleep 2
read AFTER_IN AFTER_NP <<<"$(read_udp_stats)"
DIN=$(( AFTER_IN - BEFORE_IN )); DNP=$(( AFTER_NP - BEFORE_NP ))
echo "发包后 InDatagrams=${AFTER_IN}  NoPorts=${AFTER_NP}   (delta: In=${DIN} NoPorts=${DNP})"

if [ "$DIN" -eq "$COUNT" ]; then
  echo "结论: 通达——面板 UDP 映射 + 入站通路正常（InDatagrams 精确 +${COUNT}），可以上双协议（Reality + Hysteria2）。"
  exit 0
elif [ "$DIN" -eq 0 ]; then
  echo "结论: 未到达——要么面板没加 UDP 映射/平台封 UDP，要么发错公网 IP。回面板核对映射（外部=内部）后重测；仍不通就问鸡主 → 单协议。"
  exit 1
else
  echo "结论: 计数变化异常（InDatagrams delta=${DIN}，期望 ${COUNT} 或 0）——容器可能有其它 UDP 噪声，多发一轮复测；仍异常按不可达处理。"
  exit 1
fi
