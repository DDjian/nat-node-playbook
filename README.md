# 自建节点的上架与验收工作流

一台 VPS / NAT 小鸡从**到手**到**进订阅、三端可用**的完整流程：先测能不能用，再决定装什么，装完按四步判通，出问题有坑表，退不了有备选。

写给两种人：

- **刚买了低价 NAT 机的自己**——第一件事不是装面板，是花 15 分钟测出这台机器到底能不能用；
- **维护着一小片自建节点的人**——需要的是可复用脚本、验收判据和「改坏了怎么退回去」。

## 先做这一步

机器到手，**什么都别装**，先测两条链路：

```bash
# 1) TCP：目标机起个临时服务，从外面绕代理打回来
python3 -m http.server <TCP_PORT> --bind 0.0.0.0            # 目标机
curl -sv --noproxy '*' --max-time 8 http://<IP>:<TCP_PORT>/  # 工作机

# 2) UDP：外面发 5 个包，目标机内核计数必须精确 +5
awk '/^Udp:/{print "InDatagrams",$2}' /proc/net/snmp        # 目标机，记基线
./skills/new-proxy-node/scripts/udp-check.sh <IP> <UDP_PORT> 5 <sender>
```

结论只有四种：

| TCP | UDP | 怎么办 |
|---|---|---|
| 通 | 通 | 双协议上架：Reality 保底 + Hysteria2 主力 |
| 通 | 不通 | 单协议：只上 Reality |
| 不通 | 通 | 单协议：只上 hy2。**别退货**，这类机器实测能跑到 7MB/s |
| 不通 | 不通 | 退货，趁 24–72h 的窗口，留三份证据 |

为什么非要分开测：`ping` 通不代表端口通；本机 `nc` 在透明代理下对**任意**境外 IP 都报 OPEN；只测 TCP 会把一台 UDP 极快的机器误判成废机，只测 UDP 则会装完才发现 TCP 全封。

## 文档

| 章 | 内容 |
|---|---|
| [00 总览](docs/00-总览.md) | 判据表、角色分工、架构、术语 |
| [01 开工前：先测什么](docs/01-开工前：先测什么.md) | 输入清单、TCP/UDP 实测、形态决策、**退货举证** |
| [02 安装与托管](docs/02-安装与托管.md) | sing-box 安装、凭据、配置、自愈、小容器内存纪律 |
| [03 进订阅与分流](docs/03-进订阅与分流.md) | 生成器、三层一致、直连规则、分组与标记 |
| [04 验证：怎么算通](docs/04-验证：怎么算通.md) | 四步判通、假阳性清单、测速、IP 体检、CF 隧道 |
| [05 坑表](docs/05-坑表.md) | 40 条症状 → 原因 → 修法 |
| [06 运维](docs/06-运维：改名下线退役.md) | 改名四处契约、park/dead、退役、退款后处置 |
| [99 交付清单](docs/99-交付清单.md) | BRIEF / node-info / cc-final 模板与验收 checklist |

## 脚本

```bash
skills/new-proxy-node/scripts/node-preflight.sh        # 只读事实卡：OS/libc/init/端口/残留
skills/new-proxy-node/scripts/udp-check.sh             # UDP 入站计数判定
skills/new-proxy-node/scripts/install-singbox-node.sh  # 一键上架（--dry-run 先看它要干什么）
skills/subscription-ops/scripts/park-node.sh           # 从订阅摘除一台（不删配置）
skills/subscription-ops/scripts/splice-runtime-groups.py  # 改组时把变更套进运行态配置
scripts/redact-scan.sh                                 # 提交前脱敏扫描
```

技能文档（给 agent 或当速查）：
[new-proxy-node](skills/new-proxy-node/SKILL.md) · [subscription-ops](skills/subscription-ops/SKILL.md) · [routing-change](skills/routing-change/SKILL.md)

## 自己用这套

```bash
git clone <本仓> nodes && cd nodes
mkdir -p private            # 本地私有面：真实机器、凭据、台账，永不上传
export NODES_ROOT="$PWD/private"
```

脚本都认 `$NODES_ROOT`（默认当前目录）。把每台机器放 `private/<name>/`，凭据写 `node-info.md` 并 `chmod 600`。

仓里自带 `private/` 的忽略规则和 pre-commit 脱敏扫描：

```bash
git config core.hooksPath .githooks
```

## 这个仓里没有什么

没有真实 IP、口令、私钥、订阅令牌、节点台账。`private/` 整块不进版本库，脚本与文档里只出现占位符（`<IP>` `<name>` `<sender>` `<subhost>`）和 RFC 5737 的示例地址段。

想确认：`./scripts/redact-scan.sh`。

## 许可

MIT。坑表里的数字来自实际踩坑，不代表任何平台的 SLA。
