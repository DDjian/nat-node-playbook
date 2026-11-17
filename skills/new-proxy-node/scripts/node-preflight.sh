#!/usr/bin/env bash
# node-preflight.sh — 新节点上架前的只读体检（不改远端任何东西）
#
# 用途：拿到机器后第一条命令。把「机器事实」钉死，再决定装什么包、怎么托管服务。
#      任务书≠实机（工程里已两次遇到「写 Debian 实为 Alpine」），所以全部现查。
#
# 用法：
#   node-preflight.sh root@<IP> [-p <ssh端口>] [-i <私钥>] [--expect-tcp <端口>] [--expect-udp <端口>]
#   node-preflight.sh <ssh别名>                      # 已写好 ~/.ssh/config 时更省事
#
# 输出：可直接粘进 nodes/<name>/node-info.md 的事实卡。
# 退出码：0 = 采集完成；2 = 参数错；3 = ssh 不通。
set -uo pipefail

HOST=""; SSH_PORT=""; SSH_KEY=""; EXP_TCP=""; EXP_UDP=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--port)   SSH_PORT=${2:-}; shift 2 ;;
    -i|--key)    SSH_KEY=${2:-};  shift 2 ;;
    --expect-tcp) EXP_TCP=${2:-}; shift 2 ;;
    --expect-udp) EXP_UDP=${2:-}; shift 2 ;;
    -h|--help)   sed -n '2,14p' "$0"; exit 0 ;;
    *)           HOST=${1:-}; shift ;;
  esac
done
[ -n "$HOST" ] || { echo "用法: $0 <ssh目标> [-p 端口] [-i 私钥] [--expect-tcp P] [--expect-udp P]" >&2; exit 2; }

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
[ -n "$SSH_PORT" ] && SSH_OPTS+=(-p "$SSH_PORT")
[ -n "$SSH_KEY" ]  && SSH_OPTS+=(-i "$SSH_KEY")

echo "== 预检: ${HOST} (只读) =="
if ! ssh "${SSH_OPTS[@]}" "$HOST" true 2>/dev/null; then
  echo "错误: ssh 不通。先核对 IP/端口/密钥，或面板映射（NAT 平台通常是「外部端口→22」）。" >&2
  exit 3
fi

ssh "${SSH_OPTS[@]}" "$HOST" "EXP_TCP='${EXP_TCP}' EXP_UDP='${EXP_UDP}' sh -s" <<'REMOTE'
set -u
say() { printf '%-22s %s\n' "$1" "$2"; }
have() { command -v "$1" >/dev/null 2>&1 && echo yes || echo no; }

# ---- 系统与内核 ----
say "hostname"       "$(hostname 2>/dev/null)"
if [ -r /etc/os-release ]; then
  . /etc/os-release
  say "os"            "${PRETTY_NAME:-$NAME $VERSION_ID}"
  say "os_id"         "${ID:-?}"
else
  say "os"            "unknown (/etc/os-release 缺失)"
  say "os_id"         "?"
fi
say "kernel"         "$(uname -r)"
say "arch"           "$(uname -m)"
case "$(uname -m)" in
  x86_64|amd64) ARCH_NOTE="amd64" ;;
  aarch64|arm64) ARCH_NOTE="arm64" ;;
  *) ARCH_NOTE="unknown" ;;
esac
say "sing-box资产架构" "$ARCH_NOTE"

# ---- libc：决定下 musl 还是 glibc 包 ----
if ls /lib/ld-musl-*.so.1 >/dev/null 2>&1 || [ -e /lib/ld-musl-x86_64.so.1 ]; then
  LIBC=musl
elif ldd --version 2>&1 | head -1 | grep -qi "glibc\|GNU libc\|GLIBC"; then
  LIBC=glibc
elif [ "$( (. /etc/os-release 2>/dev/null; echo "${ID:-}") )" = "alpine" ]; then
  LIBC=musl
else
  LIBC=unknown
fi
say "libc"           "$LIBC"
[ "$LIBC" = "musl" ] && say "→ 下载后缀" "-musl（必须）" || say "→ 下载后缀" "(默认 glibc 包)"

# ---- init 系统：决定服务托管写法 ----
if [ -x /sbin/openrc ]; then INIT=openrc; elif [ -x /usr/bin/systemctl ] || [ -x /bin/systemctl ]; then INIT=systemd; else INIT=unknown; fi
say "init"           "$INIT"

# ---- 资源 ----
say "cpu"            "$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo '?') 核 / $(awk -F: '/model name/{gsub(/^ +/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null || echo '?')"
if [ -r /sys/fs/cgroup/memory.max ]; then
  MAX=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
  CUR=$(awk '/^anon /{print $2}' /sys/fs/cgroup/memory.stat 2>/dev/null)
  say "cgroup memory.max" "$MAX"
  say "cgroup anon"    "${CUR:-?} bytes（真实用量；面板「内存」含 page cache 会虚高）"
else
  say "mem total"      "$(awk '/MemTotal/{printf "%.0f MB",$2/1024}' /proc/meminfo 2>/dev/null)"
fi
say "swap"           "$(awk '/SwapTotal/{printf "%.0f MB",$2/1024}' /proc/meminfo 2>/dev/null)"
say "rootfs"         "$(df -h / 2>/dev/null | awk 'NR==2{print $2" 总 / "$4" 可用 ("$5" 已用)"}')"

# ---- 时间（偏差 >90s 先校时，TLS 会出怪问题）----
say "date(UTC)"      "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
LOCAL_EPOCH=$(date -u +%s 2>/dev/null || echo 0)

# ---- 端口占用（目标端口被占就别往下走）----
say "监听 TCP"        "$(ss -tln 2>/dev/null | awk 'NR>1{print $4}' | tr '\n' ' ' | cut -c1-200)"
say "监听 UDP"        "$(ss -uln 2>/dev/null | awk 'NR>1{print $4}' | tr '\n' ' ' | cut -c1-200)"
if [ -n "${EXP_TCP:-}" ]; then
  if ss -tln 2>/dev/null | awk 'NR>1{print $4}' | grep -q ":${EXP_TCP}\$"; then
    say "期望TCP $EXP_TCP" "已被占用（换端口或先停旧进程）"
  else
    say "期望TCP $EXP_TCP" "空闲 OK"
  fi
fi
if [ -n "${EXP_UDP:-}" ]; then
  if ss -uln 2>/dev/null | awk 'NR>1{print $4}' | grep -q ":${EXP_UDP}\$"; then
    say "期望UDP $EXP_UDP" "已被占用"
  else
    say "期望UDP $EXP_UDP" "空闲 OK（有映射未起服务时本来就空闲，属正常）"
  fi
fi

# ---- 旧协议残留（迁移节点时先归档再删，别直接 rm）----
for b in /usr/local/bin/sing-box /usr/local/bin/xray /usr/bin/cloudflared /usr/local/bin/hysteria; do
  [ -e "$b" ] && say "已存在" "$b ($(du -h "$b" 2>/dev/null | awk '{print $1}'))"
done
for s in sing-box xray cloudflared hysteria; do
  P=$(ps -o pid,comm 2>/dev/null | awk -v n="$s" '$2==n{print $1}' | head -3 | tr '\n' ' ')
  [ -n "$P" ] && say "运行中" "$s pid=$P"
done

# ---- 依赖 ----
say "openssl"        "$(have openssl)$(command -v openssl >/dev/null 2>&1 && echo " ($(openssl version 2>/dev/null | head -c 40))" || echo '（Alpine 需 apk add openssl）')"
say "curl/wget"      "curl=$(have curl) wget=$(have wget) python3=$(have python3) jq=$(have jq)"
say "包管理器"        "$(command -v apk >/dev/null && echo apk; command -v apt-get >/dev/null && echo apt; command -v dnf >/dev/null && echo dnf; true)"

# ---- 出站与 DNS（节点要能自己访问外网）----
if command -v curl >/dev/null 2>&1; then
  OUT=$(curl -s -m 8 https://ipinfo.io/json 2>/dev/null | tr -d '\n' | cut -c1-200)
  say "出站(ipinfo)"   "${OUT:-失败/超时}"
  say "出站HTTP状态"   "$(curl -s -o /dev/null -m 8 -w '%{http_code}' https://www.apple.com/ 2>/dev/null)"
else
  say "出站"           "无 curl，跳过"
fi
say "DNS(apple)"     "$(getent hosts www.apple.com 2>/dev/null | head -1 || echo '解析失败')"

# ---- 未来可用的公网入口提示 ----
say "本地地址"        "$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2"="$4}' | tr '\n' ' ' | cut -c1-160)"

echo "---- 判读要点 ----"
echo "1) libc=musl → 只能下 -musl 包（装错会 not found）"
echo "2) init=openrc → 用 /etc/init.d/sing-box + rc-update；systemd → unit 文件"
echo "3) 期望端口「空闲」才继续；被占先查是不是残留旧服务"
echo "4) 出站/HTTP 200 才说明节点能自己上网（Reality handshake 需要它访问 www.apple.com:443）"
echo "5) cgroup memory.max 若 ≤256M：别在小容器上解压 92MB 包（流式传），装完看 anon 不是 cache"
REMOTE

echo
echo "== 本机侧校时（与远端比对，偏差应 <90s）=="
echo "本地 epoch: $(date -u +%s)  $(date -u '+%FT%TZ')"
