---
name: new-proxy-node
description: 上架一台新的 VPS 或 NAT 小鸡节点（sing-box：Reality [+ Hysteria2] [+ CF WS]），产出 node-info.md 等标准交付物。用于「新买了一台机器/小鸡，上架成节点」。
---

# 上架一台新节点

目标：从「拿到机器」到「`<nodes-root>/<name>/` 交付物齐 + 可进订阅」。
完整命令与逐阶段说明见 `docs/`；本技能只列**决策点与硬约束**。

> 路径约定：`<nodes-root>` 是你的节点目录（本仓根下通常是 `private/`，也可以是任意目录，脚本用 `--nodes-root` 指定）。下文 `<sender>` = 一台能向外发包的机器（你的主力机/云主机）。

## 形态决策（必做第一步）

**先确认鸡主/平台是否接受 UDP**（这一步决定后面干多少活）：

1. 看平台面板的端口转发能不能选 **UDP / TCP+UDP**；拿不准就直接问鸡主——**以实测为准**。
2. 实测法（面板映射好之后，一条命令）：

   ```bash
   skills/new-proxy-node/scripts/udp-check.sh <name> <节点公网IP> <UDP端口> 5 <sender>
   # 原理：外部 vantage 发 N 个 UDP，节点内核 InDatagrams 精确 +N = 映射与入站都通
   #      (NoPorts 只作辅助：无监听时才 +N，有监听时不涨；别把 InDatagrams 记成 NoPorts)
   ```

**决策**：

- **放 UDP（尽量争取）→ 双协议**：TCP Reality 保底 + UDP **Hysteria2** 主力；服务端用 **sing-box 单进程**（顺带承载 CF 隧道的 WS 入站）。晚高峰丢包线路下 UDP 优势巨大（实测同一台机 2.7–4.4MB/s vs TCP 0.2–1.3MB/s）。
- **不放 UDP → 单协议**：同一套 sing-box 配置，**去掉 hysteria2 入站**即可（老节点/回滚仍可用 Xray 路线）。

## 先确认（缺一不可）

0. **先测 IP 到底封了哪一半 —— TCP 与 UDP 必须分开测，别先装软件**。
   两个真实教训：装完 sing-box、验完 UDP 计数、测完速度，才发现大陆侧 TCP 全端口连不上；而只凭 TCP 判「废机退货」，又会白扔一台 hy2 实测 **6.7–7.9 MB/s**、比多数同价位机都快的机器——它的 UDP 一点没被封。

   - **① TCP**：路由器运行态加 `- IP-CIDR,<IP>/32,DIRECT,no-resolve` → `PUT /configs?force=true` 热加载 → 从本机打
     `curl -s -o /dev/null -w "%{http_code}" --resolve www.apple.com:<port>:<IP> https://www.apple.com:<port>/`
   - **200 = TCP 可用**；`000` / 超时 = 大陆侧 TCP 被阻断（换端口通常也没用，见坑表「IP 被整段墙」）。**ICMP 通（190ms 0% 丢包）不能当可用证据**——GFW 常只拦 TCP，ping 永远通。
   - **② UDP（TCP 死了更要测，这一步决定机器能不能救）**：记节点 `/proc/net/snmp` 的 `Udp:` 行第 2 列 `InDatagrams` → 家宽用
     `python3 -c "import socket;s=socket.socket(2,2);[s.sendto(b'probe%02d'%i,('<IP>',<hy2端口>)) for i in range(20)]"` 打 20 包 → 再读 `InDatagrams`，**精确 +N = UDP 全通**。
     路由器 nft 若只 `reject udp/443`（QUIC REJECT），其它 UDP 端口不劫持，root 直接发就是真直连；环境若劫持 UDP，改用 `nobody` 身份（`meta skgid 65534 return`）。
   - **判据矩阵**：TCP 通 + UDP 通 → 双协议上；**TCP 死 + UDP 通 → 单协议 hy2 照上**（Reality 砍掉，服务端配置去掉 vless 入站即可，延迟≈地理 RTT）；两者都死 → 退货。
   - 复验（TCP 那半）：删掉那条直连规则 + 热加载，若 `ssh <节点>` 从 "Connection closed" 立刻恢复正常——说明它一直在走代理、直连是死的，判定成立。
   - 没有全局 IPv6（`ip -6 addr show scope global` 为空）就没有 TCP 退路；有 v6 可以走 v6 入口（用 `<name>-v6` 独立命名，与 v4 形态区分）。
   - 测完**务必删规则 + 热加载 + 同步回滚 `template.yaml` 与路由器订阅原件**，别把死 IP 留在直连段。

1. **连接串**：`ssh root@<host> -p <port>`；NAT 平台是「面板端口→22」映射。
2. **节点端口**：只用平台放行的高位端口——TCP 给 Reality、对应高位 UDP 给 hy2（面板映射「外部=内部」）。
3. **条款**：低价 NAT 平台普遍禁「机场 / 长期占带宽」。新机定位 = **个人轻量**；大流量出口交给主力机，属**可调家规**，别把低价机当大流量管道。
4. 若这些信息不全，**停下来问**，不要猜。

## 执行要点（sing-box 主路线）

- **OS 现查现用**（任务书≠实机，已两次遇到「写 Debian 实为 Alpine」）；包管理随之切换（apt ↔ apk）。
- **只装官方源**：sing-box 官方 GitHub release；**Alpine 必须下 `-musl` 包**（默认 `linux-amd64` 是 glibc 链接，在 musl 上直接 `not found`），并用 GitHub API 的 sha256 digest 校验。
- **私钥只留服务器**：Reality 私钥写进服务器 `/etc/sing-box/config.json`（600）后删暂存；`node-info.md` 只写 UUID/pbk/sid。
- **服务托管**：OpenRC 容器 → `/etc/init.d/sing-box`（`supervise-daemon` + `respawn_delay=5`）+ `rc-update add sing-box default`；容器里 crond 常不跑，别用 `@reboot`。
- **自愈实测**：`kill -9` 的是 **sing-box 子进程**（`ps | grep "sing-box ru[n]"` 取 pid；busybox `pgrep -x` 不可靠）；pidfile 里存的是 supervisor 的 pid，杀错留孤儿。期望 ~5s 拉起。
- **hy2 共享母鸡必做加固**：sing-box 服务端 `ignore_client_bandwidth: true`（官方 hysteria 单二进制里叫 `ignoreClientBandwidth`；sing-box 的 hy2 默认 BBR、无 `congestion` 配置项，硬写会 check 失败）+ `obfs: {type: salamander}`；客户端一律**不填** up/down——防带宽提示触发 Brutal 把母鸡打爆（鸡主明确警告过）。
- **判通只认协议级 + 外部视角**：家宽挂透明代理（TPROXY）时，本机 `nc`/`/dev/tcp` 对任意境外 IP:端口都假 OPEN；用 `curl -k --resolve www.apple.com:<port>:<IP> https://www.apple.com:<port>/` 从 `<sender>` 打 Reality 回落 200 + 容器 `ss` 轮询。
- **上线后把节点 IP 加进订阅直连规则**（防二次代理）——**前提是「家宽能直连到这个 IP」**。云上 `template.yaml` 特殊直连段 → `gen.py` → 路由器重下 + **热加载**（不是 restart）。
  - **TCP 全封的节点（只能靠代理进去的）绝不能加**：hy2 的 UDP 是 mihomo 自己 dial 的 outbound、**不经过 rules 引擎**，加了零作用；反而把本机到该 IP 的 TCP（含运维口）钉成 `DIRECT` → 直连必 timeout → **自断 SSH**。判据见坑表。
- **CF 隧道（可选，治绕美/回源）**：同一 sing-box 里加 `127.0.0.1:18080` 的 VLESS-WS 入站 + cloudflared 命名隧道（`--protocol http2`，token 走 600 文件），客户端走 `<域名>:443`。
- **内存纪律（小容器）**：面板「内存」= cgroup `memory.current`，**含可回收 page cache**——92MB 的 sing-box + 40MB 的 cloudflared 二进制足以把 128M 容器顶到 90%+（有机器一天就贴顶）。真实用量看 `/sys/fs/cgroup/memory.stat` 的 `anon` + `memory.pressure`；处置 = 旧协议二进制归档删除 + 装定时回收服务（`templates/mem-reclaim.sh` + `mem-reclaim.openrc`，每 15 分钟、>60% 才回收、单次 ≤30MB 且留 20MB 缓存）。**别用大 target 硬回收**，会把 anon 挤进 swap。

## 必踩的坑（来自 5 台低价 NAT 机的真实故障）

| 坑 | 症状 | 处置 |
|---|---|---|
| **Alpine 装到 glibc 版 sing-box** | 二进制存在但 `not found` / 跑不起来 | 必须下 `sing-box-<v>-linux-amd64-musl.tar.gz`（官方有 musl 变体） |
| **大文件解压期 SSH 断连 → 二进制残缺** | sing-box **段错误**、体积比正常小（74MB vs 92MB） | 别在小容器上解压重物：本机解压后 `ssh host 'cat > /path' < 文件` 流式传送 + **sha256 双向核对**（可拿另一台同版本二进制互证） |
| **容器 `/tmp` 是 tmpfs（吃 cgroup 内存）** | 往 `/tmp` 传/解压 88MB 二进制时 SSH 半路断连，落成 40MB/37.9MB 残缺文件，跑起来**段错误**；`dd` 写 100MB 却没事、`memory.events` 里 oom_kill=0（计数器在别的 cgroup 层级） | `grep -E "[[:space:]]/tmp[[:space:]]+tmpfs[[:space:]]" /proc/mounts` 先判断；大文件一律落 overlay（`/root`、`/opt`）。`install-singbox-node.sh` 已自动选 `STAGE_DIR` |
| **IP 被整段墙（TCP 阻断、ICMP 通）** | 家宽/国内云 curl 目标端口 `000` / 20s 超时，**换端口无效**（一台机从国内云深圳测 22/80/443/34748/52261 全 timeout，443 起了 nc 也一样）；`ping` 却 168–190ms 通；美国同机房 curl 回落 **200**；加了直连规则后连 SSH 都变 "Connection closed"，删规则立刻恢复 | 上架第一步先测（见「先确认」第 0 条），**TCP 与 UDP 分开测**。这类封锁常**只打 TCP、UDP 全放** → **TCP 死但 UDP 通就上单协议 hy2，别急着退货**；两半都死才退。AS36352（HostPapa/Colocrossing）便宜段风险高 |
| **只测 TCP 就判死刑** | 见到 `000` 直接写"退货/不可用"，漏掉 UDP 通道 | 把 `000` 当"TCP 半残"而不是"整机报废"；按「先确认」第 0 条判据矩阵走 |
| **sing-box masquerade 写法** | `unknown masquerade URL scheme` | 字符串要对象形式：`{"type":"string","content":"ok"}` |
| **busybox `pgrep -x` 不灵** | 明明有进程却查不到（hysteria/sing-box） | 用 `ps \| grep 'patte[r]n'` + awk 取 pid |
| **`pkill -f`/`pgrep -f` 自 match** | 命令把自己那条 shell 杀了（ssh 退出 255） | 模式加括号：`"sing-box ru[n]"`，或用 `ps \| grep` |
| **busybox `nc` 收 UDP 有输出缓冲** | 收到了但日志文件是空的 | 读完要等进程退出；或直接用 `scripts/udp-check.sh` 计数验证（InDatagrams +N） |
| **UDP 计数法读错计数器** | 把 `InDatagrams` 当成 `NoPorts`（awk `getline` 后 `$2` 实际是 InDatagrams） | 用 `scripts/udp-check.sh`；手读要认数字行：`awk '/^Udp:/ && $2 ~ /^[0-9]+$/ {print $2, $3}'`（$2=InDatagrams, $3=NoPorts） |
| **面板内存 90%+ 就慌** | 小容器（128M/192M）面板内存接近打满 | 先看 `memory.stat` 的 `anon`（真实用量）；旧协议二进制归档删除 + `memory.reclaim` 后立刻回落（实测 99.7%→37%） |
| **缺 openssl CLI** | 自签证书步骤 exit 127 | Alpine 先 `apk add openssl`（不在 base 里） |
| **给 TCP 全封的节点加直连规则 = 自断 SSH** | `ssh <节点>` 变 `Connection closed by <IP> port <运维口>`；删掉直连规则 + 热加载后立刻恢复 | **判据是「家宽能不能直连到这个 IP」，不是「它是不是新节点」**。「新节点必须加直连」是 TCP 可达机的结论，套到 TCP 全封机上就成了自杀：hy2 的 UDP 不经 rules，规则对它零作用，却把家里设备到该 IP 的 TCP 全钉成 DIRECT。这类节点**刻意不加**，运维统一走代理组中转 |
| Xray 按扩展名判格式（老路线） | `Failed to get format of xxx.new` | 校验临时文件必须 `*.json` |
| `nc -z` 假阳性 | nc 通、curl 000 | 本机挂透明代理（TPROXY）时 nc/`/dev/tcp` 不可信；只认协议级 curl/dig/ssh |
| NAT 映射未生效 | 端口通但握手失败 | 回面板核对「外部端口 = 内部端口」，再测 |
| 家宽去程被二次代理 | 服务器自检全绿、外部 vantage 全 200，唯独家里 E2E `000`；`/connections` 该条 `up>0 / down=0`、容器零连接。**机制**：中转节点 sniffing 把目标 IP 覆盖成内层 SNI → 连错主机 | 节点 IP 未加直连：云上 `template.yaml` 加 `IP-CIDR,<IP>/32,DIRECT,no-resolve` → `gen.py` → 路由器重下 + 热加载 |
| 自愈测试打错目标 | `status: unsupervised`、旧进程变孤儿 | pidfile 是 supervisor pid；改杀子进程（`ps \| grep "xray run -c"` / `"sing-box ru[n]"`） |
| 容器抓包无权限 | tcpdump 报 `CAP_NET_RAW` | 改用 `ss -tn \| grep <port>` 轮询 + 外部 vantage |
| 体检脚本缺依赖 | `Invalid input, script exited` | 先装 `bash jq bc netcat-openbsd bind-tools iproute2` |
| SSH 会话中途断连 | 安装命令跑一半连接被关 | 先重连**核对现场**（文件/进程/端口/磁盘）再决定是否重跑；重活改流式 |
| E2E/冒烟首测瞬时 000 | 客户端有 accepted、上游无响应 | 先核对三处旁证（服务器在听 / 外部 200 / 直连规则命中），全绿则复测一次；连续失败再排查 |

## 交付物（写进 `<nodes-root>/<name>/`）

`BRIEF.md`（若来自任务书）· `node-info.md`（**600**，含分享链接/mihomo 片段/各形态凭据与验收记录，不含私钥）· `client-test.json`（+ `client-test-hy2.yaml` / `client-test-cf.json`，视形态）· `cc-final.md` · `ip-quality.txt`（可选体检）

完成后（三条都不许省）：① 处理订阅 `template.yaml` 特殊直连段 —— **家宽能直连到该 IP 就加 `DIRECT` 规则**（`gen.py` → 路由器重下 + **热加载**），**TCP 全封、只能经代理进去的节点则刻意不加**；② 用 `subscription-ops` 技能决定上架哪些形态（`<name>` / `<name>-hy2` / `<name>-cf`），并更新节点台账与索引；③ 变更记录记一条（含备份与回滚）。

## 附：模板与脚本

- 服务端 sing-box 配置模板（Reality / hysteria2 / WS 三入站占位）：`templates/singbox-server.json`（同目录）。
- UDP 入站可达性探测脚本（形态决策第一步的实测）：`scripts/udp-check.sh`（同目录）。
- 只读事实卡（OS/libc/init/cgroup/端口/旧协议残留/出站）：`scripts/node-preflight.sh`，先跑它再动手。
- 一条龙安装（装 sing-box + 生成凭据 + 渲染配置 + 托管 + 自检 + 交付种子）：`scripts/install-singbox-node.sh --help`。
- 客户端片段：Reality → mihomo vless+reality；hy2 → hysteria2 + obfs + skip-cert-verify；CF → vless+ws+tls（SNI=域名）。
