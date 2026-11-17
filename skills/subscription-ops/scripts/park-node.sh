#!/usr/bin/env bash
# park-node.sh — 云侧「把某台节点从订阅摘除」的标准动作（不删配置，只打 # park 标记）
#
# 为什么用 park 而不是删块：gen.py 对 `# park:` 的处理是「整条不渲染」（proxies 与所有组都不出现），
# 源里配置保留 → 复活只需删那一行。删块会让回滚变成手工重写，风险高。
#
# 默认 **dry-run**（只打印将加标记的节点与 diff），加 --yes 才真正写 + 生成 + 校验。
#
# 用法：
#   park-node.sh <节点名前缀> [--reason "原因"] [--host <subhost>] [--yes] [--gen-dir /opt/sub-gen]
#   park-node.sh node-a --reason "2026-10-29 弃用，由 node-b 顶替"   # 预览
#   park-node.sh node-a --reason "..." --yes                         # 执行
#
# 前缀语义：`node-a` 会命中的形态有 node-a / node-a-cf / node-a-hy2（与 sub.conf 的排除前缀展开一致）。
# 退出码：0 成功；2 参数/环境错；3 ssh 不通；5 生成或校验失败。
set -euo pipefail

TARGET=""; REASON=""; YES=0; GHOST=""; GENDIR="/opt/sub-gen"
NODES_ROOT="${NODES_ROOT:-$HOME/nodes}"
URL_MAIN_DEFAULT="$NODES_ROOT/_ops/sub/subscription-url.txt"
URL_FRIEND_DEFAULT="$NODES_ROOT/_ops/friend/subscription-url.txt"
URL_MAIN=""; URL_FRIEND=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reason) REASON=${2:-}; shift 2 ;;
    --yes) YES=1; shift ;;
    --host) GHOST=${2:-}; shift 2 ;;
    --gen-dir) GENDIR=${2:-}; shift 2 ;;
    --url-main) URL_MAIN=${2:-}; shift 2 ;;
    --url-friend) URL_FRIEND=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) TARGET=${1:-}; shift ;;
  esac
done
[ -n "$TARGET" ] || { echo "用法: $0 <节点名前缀> --host <subhost> [--reason 文本] [--yes]" >&2; exit 2; }
[ -n "$GHOST" ] || { echo "错误: 需要 --host <subhost>（跑订阅生成器的机器 ssh 别名）" >&2; exit 2; }
REASON=${REASON:-"$(date +%Y-%m-%d) 弃用（park）"}

URL_MAIN=${URL_MAIN:-$URL_MAIN_DEFAULT}
URL_FRIEND=${URL_FRIEND:-$URL_FRIEND_DEFAULT}

rsh() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$GHOST" "$@"; }
rsh true 2>/dev/null || { echo "错误: ssh $GHOST 不通" >&2; exit 3; }

echo "== park 目标: ${TARGET}*（形态前缀展开）=="
echo "   理由: $REASON"
echo "   源:   ${GHOST}:${GENDIR}/nodes.private.yaml"
[ "$YES" -eq 1 ] && echo "   模式: **执行**（会备份 + 写 + 重新生成发布）" || echo "   模式: dry-run（只预览；加 --yes 执行）"
echo

DRY=$([ "$YES" -eq 1 ] && echo 0 || echo 1)
rsh "TARGET='$TARGET' REASON='$REASON' DRY='$DRY' GENDIR='$GENDIR' sh -s" <<'REMOTE'
set -e
python3 - "$GENDIR" <<'PY'
import os, re, sys, shutil, difflib, time
gendir = sys.argv[1]
path = os.path.join(gendir, "nodes.private.yaml")
target = os.environ["TARGET"]; reason = os.environ["REASON"]; dry = os.environ["DRY"] == "1"

text = open(path, encoding="utf-8").read()
lines = text.splitlines(True)
name_re = re.compile(r"^- name:\s*(\S+)\s*$")
park_line = f"# park: {reason}\n"

out, inserted, already, hit_all = [], [], [], []
pending_park = False
for line in lines:
    s = line.strip()
    if re.match(r"^#\s*park\s*:", s):
        pending_park = True; out.append(line); continue
    m = name_re.match(line)
    if m:
        name = m.group(1)
        hit = (name == target) or name.startswith(target + "-")
        if hit:
            hit_all.append(name)
            if pending_park:
                already.append(name)
            else:
                out.append(park_line); inserted.append(name)
        pending_park = False
        out.append(line); continue
    out.append(line)

if not hit_all:
    sys.exit(f"ERROR: nodes.private.yaml 里没有名为 {target} 或以 {target}- 开头的节点")
print("命中节点:", "、".join(hit_all))
if already:  print("已 park（跳过）:", "、".join(already))
if inserted: print("将加标记:", "、".join(inserted))
if not inserted:
    print("无需改动"); sys.exit(0)

new = "".join(out)
print("\n---- diff ----")
sys.stdout.writelines(difflib.unified_diff(lines, out, fromfile="nodes.private.yaml", tofile="nodes.private.yaml(新)", n=1))
print("--------------")

if dry:
    print("\n(dry-run 未写入；加 --yes 执行)")
    sys.exit(0)

bak = f"{path}.bak-park-{time.strftime('%Y%m%d-%H%M%S')}"
shutil.copy2(path, bak)
tmp = path + ".tmp"
open(tmp, "w", encoding="utf-8").write(new)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
print(f"\n已写入（备份 {os.path.basename(bak)}）")
PY

if [ "$DRY" = "1" ]; then exit 0; fi

echo
echo "---- 重新生成 ----"
python3 "$GENDIR/gen.py"

echo
echo "---- 生成物自检 ----"
for f in /srv/sub/*/sub.yaml; do
  n=$(grep -c "^  - name:" "$f" 2>/dev/null || true)
  echo "   $(basename "$(dirname "$f")")/sub.yaml: ${n:-0} 个节点  sha=$(sha256sum "$f" | cut -c1-12)"
done
REMOTE

if [ "$YES" -ne 1 ]; then
  echo
  echo "预览结束。确认无误后加 --yes 执行。"
  exit 0
fi

echo
echo "== 三层一致校验（线上 curl vs 服务器文件）=="
FAIL=0
for pair in "main:$URL_MAIN" "friend:$URL_FRIEND"; do
  label=${pair%%:*}; urlfile=${pair#*:}
  [ -f "$urlfile" ] || { echo "   $label: 缺 $urlfile，跳过"; continue; }
  URL=$(cat "$urlfile")
  TOK=$(printf '%s' "$URL" | sed -E 's#.*/([A-Za-z0-9_-]+)/sub\.yaml.*#\1#')
  [ "$TOK" != "$URL" ] || { echo "   $label: URL 解析失败，跳过"; continue; }
  LIVE=$(curl -s -m 15 -A "clash.meta/1.19.30" "$URL" | sha256sum | awk '{print $1}')
  SRV=$(rsh "sha256sum /srv/sub/$TOK/sub.yaml 2>/dev/null | awk '{print \$1}'" || true)
  if [ -n "$LIVE" ] && [ "$LIVE" = "$SRV" ]; then
    echo "   $label: 一致 ${LIVE:0:12}…"
  else
    echo "   $label: **不一致** 线上=${LIVE:0:12}… 服务器=${SRV:0:12}…"; FAIL=1
  fi
done
[ "$FAIL" -eq 0 ] || { echo "错误: 三层不一致，别动路由器" >&2; exit 5; }

cat <<'NEXT'

== 下一步（路由器侧，手工执行）==
  1) 重下订阅 → python3 splice-runtime-groups.py <新订阅> /etc/openclash/<sub>.yaml
  2) 独立目录 clash_meta -t 校验（去掉 external-ui 行）
  3) PUT /configs?force=true，判据：返回 204 且 pidof clash 不变
  4) **刷新 /etc/openclash/custom/<sub>-failover-good.yaml**（否则 failover 回滚会把旧节点带回来）
  5) 客户端重拉订阅；台账 / README / 变更记录 三条增量更新
NEXT
