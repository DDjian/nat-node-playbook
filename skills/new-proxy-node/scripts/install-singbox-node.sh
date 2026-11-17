#!/usr/bin/env bash
# install-singbox-node.sh — 新节点一条龙：装 sing-box（musl/glibc 自动判定）+ 生成凭据
#                          + 渲染服务端配置 + 服务托管 + 自检 + 生成 node-info 种子
#
# 设计前提（来自工程已踩的坑）：
#   * 小容器上解压 92MB 包会断连留残缺二进制 → 一律本机下载解压，再流式传入
#   * Alpine 必须 -musl 包（装错报 "not found"）
#   * 私钥只留服务器（/etc/sing-box/config.json 600），本脚本不打印、不落盘到工程
#   * 共享母鸡：hy2 强制 ignore_client_bandwidth + obfs salamander（模板已含）
#   * 幂等：重复执行会备份旧 config 并重启服务；不给 --force 时不覆盖已有 config
#
# 用法：
#   install-singbox-node.sh --host <ssh目标> --name <节点名> --tcp-port <端口> \
#       [--udp-port <端口>] [--mode dual|reality|triple] [--ws-path /xxxx] \
#       [--ext-tcp <外部端口>] [--ext-udp <外部端口>] \
#       [--version 1.14.4|latest] [--ssh-port P] [--ssh-key F] [--nodes-root DIR] [--dry-run] [--force]
#
#   --nodes-root  节点交付物落点（默认当前目录）。本机习惯：从工作仓根执行，
#                 或显式 --nodes-root <你的私有节点目录>。
#
# 退出码：0 成功；2 参数/环境不满足；3 ssh 不通；4 二进制校验失败；5 配置/服务失败
set -euo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
TEMPLATE="$SELF_DIR/../templates/singbox-server.json"
CACHE="${SINGBOX_CACHE:-${XDG_CACHE_HOME:-$HOME}/.cache/singbox}"

HOST=""; NAME=""; TCP_PORT=""; UDP_PORT=""; MODE="dual"; WS_PATH=""; EXT_TCP=""; EXT_UDP=""
VERSION="1.14.4"; SSH_PORT=""; SSH_KEY=""; DRY_RUN=0; FORCE=0; DOMAIN=""
NODES_ROOT="${NODES_ROOT:-$PWD}"

die() { echo "错误: $*" >&2; exit "${2:-2}"; }
log() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
sub() { printf '   %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST=${2:-}; shift 2 ;;
    --name) NAME=${2:-}; shift 2 ;;
    --tcp-port) TCP_PORT=${2:-}; shift 2 ;;
    --udp-port) UDP_PORT=${2:-}; shift 2 ;;
    --mode) MODE=${2:-}; shift 2 ;;
    --ws-path) WS_PATH=${2:-}; shift 2 ;;
    --domain) DOMAIN=${2:-}; shift 2 ;;
    --ext-tcp) EXT_TCP=${2:-}; shift 2 ;;
    --ext-udp) EXT_UDP=${2:-}; shift 2 ;;
    --version) VERSION=${2:-}; shift 2 ;;
    --ssh-port) SSH_PORT=${2:-}; shift 2 ;;
    --ssh-key) SSH_KEY=${2:-}; shift 2 ;;
    --nodes-root) NODES_ROOT=${2:-}; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[ -n "$HOST" ] && [ -n "$NAME" ] && [ -n "$TCP_PORT" ] || die "缺少 --host / --name / --tcp-port"
case "$MODE" in dual|reality|triple) ;; *) die "--mode 只能是 dual|reality|triple" ;; esac
case "$MODE" in dual|triple) [ -n "$UDP_PORT" ] || die "--mode $MODE 需要 --udp-port" ;; esac
[ "$MODE" = "triple" ] && { [ -n "$WS_PATH" ] || die "--mode triple 需要 --ws-path（CF 隧道 WS 路径）"; }
[ -f "$TEMPLATE" ] || die "模板缺失: $TEMPLATE"
EXT_TCP=${EXT_TCP:-$TCP_PORT}
EXT_UDP=${EXT_UDP:-${UDP_PORT:-}}
WS_PATH=${WS_PATH:-/$(openssl rand -hex 5 2>/dev/null || echo wsdefault)}

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
[ -n "$SSH_PORT" ] && SSH_OPTS+=(-p "$SSH_PORT")
[ -n "$SSH_KEY" ]  && SSH_OPTS+=(-i "$SSH_KEY")
rsh() { ssh "${SSH_OPTS[@]}" "$HOST" "$@"; }

# 临时目录（含私钥渲染结果）→ 退出必删
TMP=$(mktemp -d); chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

log "0/9 远端环境探测"
rsh true 2>/dev/null || die "ssh 不通: $HOST（核对面板端口映射 / 密钥）" 3
read -r R_ARCH R_LIBC R_INIT R_HASBIN < <(rsh "sh -s" <<'EOF'
arch=$(uname -m); case "$arch" in x86_64|amd64) A=amd64 ;; aarch64|arm64) A=arm64 ;; *) A=unknown ;; esac
if ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; then L=musl
elif ldd --version 2>&1 | head -1 | grep -qi glibc; then L=glibc
elif [ "$( (. /etc/os-release 2>/dev/null; echo ${ID:-}) )" = alpine ]; then L=musl
else L=unknown; fi
if [ -x /sbin/openrc ]; then I=openrc; elif [ -x /usr/bin/systemctl ] || [ -x /bin/systemctl ]; then I=systemd; else I=unknown; fi
[ -x /usr/local/bin/sing-box ] && B=yes || B=no
echo "$A $L $I $B"
EOF
)
sub "arch=$R_ARCH libc=$R_LIBC init=$R_INIT 已有sing-box=$R_HASBIN"
[ "$R_ARCH" = "unknown" ] && die "不支持的架构（只有 amd64 / arm64）"
[ "$R_INIT" = "unknown" ] && die "既非 openrc 也非 systemd，本脚本不支持（手工按 docs/ 逐章走）"

EXISTING_CFG=0
rsh "[ -f /etc/sing-box/config.json ]" 2>/dev/null && EXISTING_CFG=1 || true
if [ "$EXISTING_CFG" -eq 1 ] && [ "$FORCE" -eq 0 ]; then
  [ "$DRY_RUN" -eq 1 ] && sub "警告：远端已有 /etc/sing-box/config.json（真跑会被拒，需 --force）" \
    || die "远端已有 /etc/sing-box/config.json（疑似在跑的节点）。确认要覆盖请加 --force"
fi

log "1/9 解析版本与下载"
if [ "$VERSION" = "latest" ]; then
  VERSION=$(curl -fsSL --max-time 20 https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/^v//') \
    || die "取 latest 版本失败"
  sub "latest → $VERSION"
fi
SUFFIX=""; [ "$R_LIBC" = "musl" ] && SUFFIX="-musl"
ASSET="sing-box-${VERSION}-linux-${R_ARCH}${SUFFIX}.tar.gz"
URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/${ASSET}"
mkdir -p "$CACHE/bin"
mkdir -p "$HOME/nodes/$NAME"; chmod 755 "$HOME/nodes/$NAME"
BIN_LOCAL="$CACHE/bin/sing-box-${VERSION}-linux-${R_ARCH}${SUFFIX}"
if [ -f "$BIN_LOCAL" ] && [ -x "$BIN_LOCAL" ] && [ -s "$BIN_LOCAL" ]; then
  sub "命中缓存: $BIN_LOCAL"
else
  sub "下载 $ASSET（31MB 量级，请稍候）"
  curl -fsSL --retry 3 --max-time 300 -o "$CACHE/$ASSET" "$URL" || die "下载失败: $URL"
  if command -v jq >/dev/null 2>&1; then
    WANT=$(curl -fsSL --max-time 20 "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v${VERSION}" \
      | jq -r --arg a "$ASSET" '.assets[]|select(.name==$a)|.digest' | sed 's/^sha256://')
    GOT=$(sha256sum "$CACHE/$ASSET" | awk '{print $1}')
    if [ -n "$WANT" ] && [ "$WANT" != "null" ]; then
      [ "$WANT" = "$GOT" ] && sub "GitHub digest 校验通过 ($GOT)" || die "digest 不一致！want=$WANT got=$GOT" 4
    else
      sub "GitHub 未提供 digest，跳过（仍做传输双向 sha256）"
    fi
  fi
  EXDIR=$(mktemp -d "$CACHE/ex.XXXXXX")
  tar -xzf "$CACHE/$ASSET" -C "$EXDIR"
  SRC=$(find "$EXDIR" -maxdepth 3 -type f -name sing-box 2>/dev/null | head -1 || true)
  [ -n "$SRC" ] || { rm -rf "$EXDIR"; die "解压后找不到 sing-box 二进制" 4; }
  cp -f "$SRC" "$BIN_LOCAL"; chmod 755 "$BIN_LOCAL"
  rm -rf "$EXDIR"
fi
LOCAL_SHA=$(sha256sum "$BIN_LOCAL" | awk '{print $1}')
sub "本地二进制: $(du -h "$BIN_LOCAL" | awk '{print $1}') sha256=${LOCAL_SHA:0:16}…"

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY-RUN：以下动作不会执行"
  cat <<EOF
   1) 流式传送 $BIN_LOCAL → $HOST:/tmp/sing-box.new（双向 sha256 核对）
   2) install -m 755 → /usr/local/bin/sing-box（旧文件先备份）
   3) 生成凭据：UUID / Reality keypair（私钥只落服务器）/ sid / hy2 密码 / obfs 密码
   4) ${MODE} 模式渲染 config → /etc/sing-box/config.json (600)，sing-box check 通过才生效
   5) ${R_INIT} 服务托管（respawn 5s）+ 开机自启
   6) 自检：监听 :${TCP_PORT}${UDP_PORT:+ / UDP :${UDP_PORT}}、进程、日志
   7) 写 ~/nodes/${NAME}/node-info.generated.md (600) + client-test.json
   套餐：mode=${MODE} tcp=${TCP_PORT}${UDP_PORT:+ udp=${UDP_PORT}} ext_tcp=${EXT_TCP}${EXT_UDP:+ ext_udp=${EXT_UDP}} version=${VERSION} libc=${R_LIBC}
EOF
  exit 0
fi

# 落点选择：/tmp 若是 tmpfs（内存盘）就改用 overlay 路径。
# 踩过（2026-10-29，一台 128M 容器）：88MB 二进制解压/暂存进 tmpfs → 吃满 cgroup 内存
#   → 内核杀 sshd → 传输中断 → 二进制残缺（40MB/37.9MB），跑起来直接 Segmentation fault。
STAGE_DIR=${STAGE_DIR:-$(rsh 'if grep -qE "[[:space:]]/tmp[[:space:]]+tmpfs[[:space:]]" /proc/mounts 2>/dev/null; then echo /root; else echo /tmp; fi')}
[ -n "$STAGE_DIR" ] || STAGE_DIR=/tmp
[ "$STAGE_DIR" = "/tmp" ] || sub "远端 /tmp 是 tmpfs → 暂存改用 ${STAGE_DIR}（避免吃满 cgroup 内存）"

log "2/9 流式传送二进制"
if [ "${SKIP_TRANSFER:-0}" = "1" ]; then
  REMOTE_SHA=$(rsh "sha256sum /usr/local/bin/sing-box 2>/dev/null | awk '{print \$1}'")
  [ "$REMOTE_SHA" = "$LOCAL_SHA" ] \
    || die "SKIP_TRANSFER=1 但远端 /usr/local/bin/sing-box 与本地二进制不一致（远端 ${REMOTE_SHA:-缺失}）" 4
  sub "跳过传输：远端已有同版本二进制 ${REMOTE_SHA:0:16}…"
else
  rsh "cat > ${STAGE_DIR}/sing-box.new" < "$BIN_LOCAL"
  REMOTE_SHA=$(rsh "sha256sum ${STAGE_DIR}/sing-box.new | awk '{print \$1}'")
  [ "$REMOTE_SHA" = "$LOCAL_SHA" ] || die "传输后 sha256 不一致（远端 $REMOTE_SHA）" 4
  sub "双向 sha256 一致 ${REMOTE_SHA:0:16}…"
fi

log "3/9 安装 /usr/local/bin/sing-box"
if [ "${SKIP_TRANSFER:-0}" = "1" ]; then
  sub "二进制已就位，跳过安装"
else
rsh "STAGE_DIR='$STAGE_DIR' sh -s" <<'EOF'
set -e
[ -x /usr/local/bin/sing-box ] && cp -a /usr/local/bin/sing-box "/usr/local/bin/sing-box.bak-$(date +%Y%m%d-%H%M%S)"
install -m 755 "$STAGE_DIR/sing-box.new" /usr/local/bin/sing-box
rm -f "$STAGE_DIR/sing-box.new"
/usr/local/bin/sing-box version | head -1
EOF
fi
sub "$(rsh '/usr/local/bin/sing-box version | head -1')"

log "4/9 生成凭据（私钥只在服务器）"
UUID=$(cat /proc/sys/kernel/random/uuid)
SID=$(openssl rand -hex 8)
HY2_PASS=$(openssl rand -base64 24 | tr -d '\n')
HY2_OBFS=$(openssl rand -base64 24 | tr -d '\n')
KEYPAIR=$(rsh "/usr/local/bin/sing-box generate reality-keypair")
PRIV=$(printf '%s\n' "$KEYPAIR" | awk -F': *' '/PrivateKey/{print $2}')
PUB=$(printf '%s\n'  "$KEYPAIR" | awk -F': *' '/PublicKey/{print $2}')
[ -n "$PRIV" ] && [ -n "$PUB" ] || die "Reality keypair 生成失败" 5
sub "UUID=$UUID  sid=$SID  pbk=$PUB"

HAVE_HY2=0; case "$MODE" in dual|triple) HAVE_HY2=1 ;; esac
HAVE_WS=0;  case "$MODE" in triple) HAVE_WS=1 ;; esac

if [ "$HAVE_HY2" -eq 1 ]; then
  log "4.1/9 自签证书（hy2 用，CN=$NAME）"
  rsh "NAME='$NAME' sh -s" <<'EOF'
set -e
if ! command -v openssl >/dev/null 2>&1; then
  if command -v apk >/dev/null 2>&1; then apk add --no-cache openssl >/dev/null; else apt-get update -qq && apt-get install -y -qq openssl >/dev/null; fi
fi
mkdir -p /etc/sing-box /var/log/sing-box
if [ ! -f "/etc/sing-box/$NAME.crt" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
    -keyout "/etc/sing-box/$NAME.key" -out "/etc/sing-box/$NAME.crt" >/dev/null 2>&1
  chmod 600 "/etc/sing-box/$NAME.key"; chmod 644 "/etc/sing-box/$NAME.crt"
  echo "证书已生成"
else
  echo "证书已存在，复用"
fi
EOF
fi

log "5/9 渲染服务端配置"
python3 - "$TEMPLATE" "$TMP/config.json" "$UUID" "$TCP_PORT" "$UDP_PORT" "$PRIV" "$SID" \
  "$HY2_PASS" "$HY2_OBFS" "$WS_PATH" "$NAME" "$MODE" <<'PY'
import json, sys
tpl, out, uuid, tcp, udp, priv, sid, hyp, obfs, wsp, name, mode = sys.argv[1:13]
d = json.load(open(tpl))
d.pop("_README", None)
keep = {"vless-reality"}
if mode in ("dual", "triple"): keep.add("hysteria2")
if mode == "triple": keep.add("vless-ws")
d["inbounds"] = [i for i in d["inbounds"] if i.get("tag") in keep]
for i in d["inbounds"]:
    if i["tag"] == "vless-reality":
        i["listen_port"] = int(tcp)
        i["users"] = [{"uuid": uuid, "flow": "xtls-rprx-vision"}]
        i["tls"]["reality"]["private_key"] = priv
        i["tls"]["reality"]["short_id"] = [sid]
    elif i["tag"] == "hysteria2":
        i["listen_port"] = int(udp)
        i["users"] = [{"password": hyp}]
        i["ignore_client_bandwidth"] = True
        i["obfs"] = {"type": "salamander", "password": obfs}
        i["tls"]["certificate_path"] = f"/etc/sing-box/{name}.crt"
        i["tls"]["key_path"] = f"/etc/sing-box/{name}.key"
    elif i["tag"] == "vless-ws":
        i["users"] = [{"uuid": uuid}]
        i["transport"] = {"type": "ws", "path": wsp}
        i["listen"] = "127.0.0.1"; i["listen_port"] = 18080
json.dump(d, open(out, "w"), indent=2, ensure_ascii=False)
PY
sub "入站: $(python3 -c "import json,sys;print(','.join(i['tag'] for i in json.load(open(sys.argv[1]))['inbounds']))" "$TMP/config.json")"

log "6/9 校验并落地配置"
rsh "cat > /tmp/config.json.new" < "$TMP/config.json"
rsh "/usr/local/bin/sing-box check -c /tmp/config.json.new" || die "sing-box check 失败（配置未生效）" 5
rsh "set -e; mkdir -p /etc/sing-box /var/log/sing-box; \
  [ -f /etc/sing-box/config.json ] && cp -a /etc/sing-box/config.json /etc/sing-box/config.json.bak-\$(date +%Y%m%d-%H%M%S); \
  mv /tmp/config.json.new /etc/sing-box/config.json; chmod 600 /etc/sing-box/config.json; ls -l /etc/sing-box/config.json"
sub "配置已落地（600）"

log "7/9 服务托管"
if [ "$R_INIT" = "openrc" ]; then
  rsh "NAME='$NAME' MODE='$MODE' sh -s" <<'EOF'
set -e
cat > /etc/init.d/sing-box <<'INIT'
#!/sbin/openrc-run
name="sing-box"
description="sing-box (__NAME__: __MODE__)"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
supervisor="supervise-daemon"
pidfile="/run/sing-box.pid"
respawn_delay=5
respawn_max=0
output_log="/var/log/sing-box/supervise.out.log"
error_log="/var/log/sing-box/supervise.err.log"

depend() { need net; }
start_pre() { mkdir -p /var/log/sing-box; chmod 755 /var/log/sing-box; }
INIT
sed -i "s/__NAME__/$NAME/; s/__MODE__/$MODE/" /etc/init.d/sing-box
chmod 755 /etc/init.d/sing-box
rc-update add sing-box default >/dev/null 2>&1 || true
rc-service sing-box restart >/dev/null 2>&1 || rc-service sing-box start
sleep 2
rc-service sing-box status
EOF
else
  rsh "NAME='$NAME' MODE='$MODE' sh -s" <<'EOF'
set -e
cat > /etc/systemd/system/sing-box.service <<UNIT
[Unit]
Description=sing-box ($NAME: $MODE)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
RestartSec=5
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1 || true
systemctl restart sing-box
sleep 2
systemctl is-active sing-box
EOF
fi

log "8/9 自检"
rsh "TCP='$TCP_PORT' UDP='$UDP_PORT' sh -s" <<'EOF'
echo "-- 监听 --"
ss -tln | awk 'NR>1{print $4}' | grep ":${TCP}\$" || echo "!! TCP ${TCP} 未监听"
[ -n "$UDP" ] && { ss -uln | awk 'NR>1{print $4}' | grep ":${UDP}\$" || echo "!! UDP ${UDP} 未监听"; }
echo "-- 进程 --"
ps | grep "sing-box ru[n]" | awk '{print "   pid="$1}'
echo "-- 日志尾 --"
tail -5 /var/log/sing-box/box.log 2>/dev/null || true
EOF

log "9/9 生成交付种子"
NODE_DIR="$NODES_ROOT/$NAME"
mkdir -p "$NODE_DIR"
PUB_SHA=$PUB
cat > "$NODE_DIR/node-info.generated.md" <<EOF
# $NAME 节点信息（脚本生成 $(date '+%Y-%m-%d %H:%M')，人工补齐外部端口/验收后改名 node-info.md）

- 服务器：$(rsh "curl -s -m 6 https://ipinfo.io/ip 2>/dev/null || echo '<公网IP>'")（SSH：$(echo "$HOST" | sed 's/.*@//')${SSH_PORT:+ :$SSH_PORT}）
- 形态：mode=$MODE（$( [ "$HAVE_HY2" -eq 1 ] && echo -n 'Reality + Hysteria2' || echo -n 'Reality' )$( [ "$HAVE_WS" -eq 1 ] && echo ' + CF WS' ))
- sing-box：$VERSION（libc=$R_LIBC，init=$R_INIT，sha256=${LOCAL_SHA:0:16}…）
- 端口：Reality TCP $TCP_PORT（外部 $EXT_TCP）$( [ "$HAVE_HY2" -eq 1 ] && echo -n "；Hysteria2 UDP $UDP_PORT（外部 $EXT_UDP）" )$( [ "$HAVE_WS" -eq 1 ] && echo -n "；CF WS 127.0.0.1:18080" )

## 客户端凭据（**600 文件，不进 docs/聊天**）
- UUID: \`$UUID\`
- Reality pbk: \`$PUB\`
- Reality sid: \`$SID\`
$( [ "$HAVE_HY2" -eq 1 ] && printf -- "- Hysteria2 密码: \`%s\`\n- obfs(salamander) 密码: \`%s\`\n" "$HY2_PASS" "$HY2_OBFS" )
$( [ "$HAVE_WS" -eq 1 ] && printf -- "- CF WS path: \`%s\`（域名 ${DOMAIN:-<域名>}）\n" "$WS_PATH" )
- Reality 私钥：**只在服务器** /etc/sing-box/config.json（600），本文件不记录

## 分享链接
\`\`\`
vless://$UUID@<公网IP>:$EXT_TCP?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=$PUB&sid=$SID&type=tcp#$NAME
$( [ "$HAVE_HY2" -eq 1 ] && printf 'hysteria2://%s@<公网IP>:%s/?sni=%s&insecure=1&obfs=salamander&obfs-password=%s#%s-hy2\n' "$HY2_PASS" "$EXT_UDP" "$NAME" "$HY2_OBFS" "$NAME" )
\`\`\`

## 待补（人工）
- [ ] 面板映射核实：TCP $EXT_TCP→$TCP_PORT、UDP ${EXT_UDP:-—}→${UDP_PORT:-—}、SSH 外部→22
- [ ] UDP 入站实测：\`skills/new-proxy-node/scripts/udp-check.sh $NAME <IP> $UDP_PORT 5 <发送方别名>\`
- [ ] 外部 vantage 协议级验证（curl --resolve 回落 200）
- [ ] IP 体检（可选）
- [ ] 进订阅 + 直连规则 + 台账/README/变更记录/monitor
EOF
chmod 600 "$NODE_DIR/node-info.generated.md"

python3 - "$NODE_DIR/client-test.json" "$NAME" "$UUID" "$EXT_TCP" "$PUB" "$SID" <<'PY'
import json, sys
out, name, uuid, port, pbk, sid = sys.argv[1:7]
cfg = {"log": {"level": "info"},
       "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": 10888}],
       "outbounds": [{"type": "vless", "server": "<公网IP>", "server_port": int(port), "uuid": uuid,
                      "network": "tcp", "tls": True, "udp": True, "flow": "xtls-rprx-vision",
                      "servername": "www.apple.com", "client-fingerprint": "chrome",
                      "reality-opts": {"public-key": pbk, "short-id": sid}, "tag": name}]}
json.dump(cfg, open(out, "w"), indent=2, ensure_ascii=False)
PY

echo
echo "======================================================"
echo "完成。交付种子：$NODE_DIR/node-info.generated.md (600)"
echo "下一步（顺序别反）："
echo "  1) UDP 实测：  $SELF_DIR/udp-check.sh $NAME <公网IP> ${UDP_PORT:-<udp>} 5 ${SENDER:-<发送方别名>}"
echo "  2) 外部验证：  ssh ${SENDER:-<发送方别名>} 'curl -s -o /dev/null -w \"%{http_code}\\n\" --resolve www.apple.com:$TCP_PORT:<公网IP> https://www.apple.com:$TCP_PORT/'   # 期望 200"
echo "  3) 再进订阅（先加直连规则！）见 docs/03-进订阅与分流.md"
echo "======================================================"
