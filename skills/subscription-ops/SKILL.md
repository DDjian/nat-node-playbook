---
name: subscription-ops
description: 维护自建订阅——加/改节点、改规则模板、重新生成发布、更新路由器与手机/PC 客户端。用于「订阅里要加个节点/改条规则/客户端不更新」的任务。
---

# 自建订阅运维

架构与完整规则口径见 `docs/03-进订阅与分流.md`。**唯一源头是订阅生成机上的生成器**（`<subhost>:/opt/sub-gen/`），永远不要手改已发布的 `/srv/sub/*/sub.yaml`。

> 占位符：`<subhost>` = 跑生成器的服务器 ssh 别名；`<router>` = 软路由 ssh 别名；`<sub>` = OpenClash 订阅配置基名；`<订阅占位符>` = 带令牌的分发 URL（只存 600 文件）。

## 改东西的标准流程

```bash
# 1) 改源头（模板=规则/DNS/组；节点清单=凭据）
ssh <subhost> 'vi /opt/sub-gen/template.yaml'          # 或 nodes.private.yaml（600）

# 2) 重新生成：自动 结构自检 → mihomo -t 校验 → 原子发布
ssh <subhost> 'python3 /opt/sub-gen/gen.py'
#    看到「校验：mihomo -t 通过」；内容无变化会打印「跳过发布」

# 3) 路由器更新（下载 + 热加载；不再 restart，长连接不断、无冷启动窗口）
ssh <router> 'curl -s -A "clash.meta/1.19.30" -o /tmp/<sub>-new.yaml "<订阅占位符>" && sha256sum /tmp/<sub>-new.yaml \
  && cp -a /etc/openclash/config/<sub>.yaml /etc/openclash/config/<sub>.yaml.bak-$(date +%Y%m%d-%H%M%S) \
  && mv /tmp/<sub>-new.yaml /etc/openclash/config/<sub>.yaml'
# 把本次改动同样套到运行态文件（目前通常只有规则行差异），再 API 热加载：
ssh <router> 'sed -i "s/<旧行>/<新行>/" /etc/openclash/<sub>.yaml'    # ← 按本次 diff 调整
#    改的是 proxy-groups 块（加组/改成员）时别用 sed：用 scripts/splice-runtime-groups.py 重拼整块
#    （它处理订阅与运行态两套缩进，并自带「组名不重复」自检），再 clash_meta -t 校验后覆盖
ssh <router> 'SEC=$(sed -n "s/^secret: *//p" /etc/openclash/<sub>.yaml | head -1 | tr -d "\""); \
  curl -s -X PUT -H "Authorization: Bearer $SEC" -H "Content-Type: application/json" \
  -d "{\"path\":\"/etc/openclash/<sub>.yaml\"}" "http://127.0.0.1:9090/configs?force=true"; pidof clash'
# 判据：命令返回且 pidof clash 的 pid 不变 = 热加载成功（进程未换、连接未断）。
# 注意：涉及监听端口/DNS/防火墙/TUN 的改动不能热加载，仍需择时 restart。

# 4) 手机/PC：客户端里刷新订阅
```

## 验收（必须做，别跳）

```bash
S=$(ssh <router> 'sed -n "s/^secret: *//p" /etc/openclash/<sub>.yaml | head -1' | tr -d "\"'")
# 组与节点
ssh <router> "curl -s -H 'Authorization: Bearer $S' http://127.0.0.1:9090/proxies | jq -r '.proxies|to_entries[]|select(.value.type==\"Selector\")|\"\\(.key) -> \\(.value.now)\"'"
# 新规则是否生效
ssh <router> "curl -s -H 'Authorization: Bearer $S' http://127.0.0.1:9090/rules | jq -r '.rules[]|select(.payload|contains(\"<关键字>\"))|\"\\(.payload) -> \\(.proxy)\"'"
# 真实出口
curl -s https://icanhazip.com                                    # 普通境外 → 期望 Proxy 组当前成员
curl -s https://chatgpt.com/cdn-cgi/trace | grep ip=              # AI → 期望 AI 组当前成员
```

## 加节点

0. **前置**：先按 `skills/new-proxy-node` 的「形态决策」确定鸡主是否放 UDP——放则上 `<name>`（Reality）+ `<name>-hy2` 双协议（sing-box），不放则只上 `<name>`。**新节点 IP 是否进 `template.yaml` 特殊直连段**（`IP-CIDR,<IP>/32,DIRECT,no-resolve`）取决于家宽能否直连它：能直连就必须加（否则家宽 E2E 假失败），TCP 全封的机器**刻意不加**（加了自断 SSH，见 `skills/new-proxy-node` 坑表）。
1. 在 `nodes.private.yaml` 末尾追加 mihomo 格式节点（参考同文件既有条目）；每种形态**独立命名、独立条目**：`<name>` / `<name>-hy2` / `<name>-cf`
2. 重新生成（组员自动包含新节点：**`Proxy-Auto` 收全部形态、`YouTube-Auto` 收非 `-cf` 形态**，`Proxy`/`YouTube` 两个手动组的成员表也会带上它；`AI` 组是**显式名单**，不自动跟随，要加需改 `gen.py` 的 AI 名单）。**不要手改 `proxy-groups` 块**——模板里的 `{{PROXY_AUTO_MEMBERS}}` / `{{YOUTUBE_AUTO_MEMBERS}}` / `{{NODE_MEMBERS}}` 由 `gen.py` 从 `nodes.private.yaml` 自动渲染，手改会在下次生成时被覆盖
   - **排除语义**：`sub.conf` 的 `PROFILE=<名>:<令牌>:<排除>` 按**形态前缀展开** —— 写 `NodeA` 会连带排除 `NodeA-cf` 等同机形态。新增同机形态（`-cf` / `-hy2`）后**不必**回头补排除清单；但**绝不能**把排除写成精确名匹配（旧写法会让新形态漏进对外分发档，实际发生过，窗口约 1 分钟）。
   - **带宽口径**：节点带宽小（10M 这类，跑不动 4K）时，在 `nodes.private.yaml` 该节点块上方加一行 `# low-bw: 10M`，`gen.py` 会自动把它从 `YouTube-Auto` / `YouTube` 两个组排除；Proxy 侧不受影响。
   - **月流量标签**：在节点块上方加一行 `# quota: US 600G/月`（简短、无语义空格要求），客户端可见名会变成 `<基名> · <标签>`，例 `node-b · JP 300G/月`。语义是**该机器每月总额度**，不是实时余量；同一台机器的各形态各写一次同名标签。不写就不带后缀。
   - **暂时下线**：不删块，只在节点块上方加 `# park: <原因>` —— `gen.py` 该节点**整条不渲染**（proxies 与全部组都不出现），启动时会打印「已 park（不进订阅）：…」。复活只要删掉那行 `# park:` 再生成，不用碰代码。与 `# dead`（仍下发、只摘出自动组）区分开。
3. 路由器重下订阅 + 热加载后，`/proxies` 确认新条目在列并实测延迟
4. 更新节点台账 + 节点索引 + 变更记录（记备份与回滚）

## 节点改名 / 下线

**节点名是跨系统的契约**，改一次要连带四处，漏一处就是静默失效：

1. `nodes.private.yaml` 改 `- name:` → `python3 /opt/sub-gen/gen.py`（组员由模板渲染，不用手改组）
2. 路由器：`scp` 新订阅到 `/tmp` → `splice-runtime-groups.py <新订阅> /etc/openclash/<sub>.yaml` → **`clash_meta -t`** 校验 → `mv` 覆盖 + `PUT /configs?force=true`（`pidof clash` 不变才算热加载成功）；同时更新 `/etc/openclash/config/<sub>.yaml`（订阅原件），否则重启带回旧名
3. 路由器上**任何硬编码节点名的脚本**都要改成按前缀动态发现。典型两处：兜底切换脚本（写死某个节点名，改名后 API 返回 400、静默不兜底）与自动选点脚本的 AI 白名单（应改成「`AI.now` ∈ `AI.all`」）
4. `sub.conf` 里对外分发档位的 `AI` 名单若引用了旧名，必须同步改（引用了不存在的节点会被 `gen.py` 的结构自检拦下、整批不发布 —— 这是好事，别绕过）

**校验 `clash_meta -t` 的两个坑**：运行态里 `external-ui` 指向 `/usr/share/openclash/ui`，用 `-d /etc/openclash` 直接跑会报 `path is not subpath of home directory or SAFE_PATHS`（`SAFE_PATHS` 用空格分隔、逗号无效）。干净做法是拉个独立目录：`cp GeoIP.dat GeoSite.dat ASN.mmdb Country.mmdb /tmp/vtest/`，`sed "/external-ui/d"` 掉那一行，再 `clash_meta -d /tmp/vtest -f /tmp/vtest/config.yaml -t`，看到 `test is successful` 才算过。

**客户端影响**：改名后旧名字的选择记忆失效，`Proxy` / `YouTube` 会落回 `Proxy-Auto`，`AI` 除非也改名否则仍在原节点。改完提醒客户端重拉订阅。

## 硬约束

- 私钥/令牌永不进聊天与文档；订阅链接只存 `<nodes-root>/_ops/sub/subscription-url.txt`（600）。
- 生成器改动后必须确认**三层一致**：生成物 sha == 线上 sha；路由器 `/rules`、`/proxies` 与预期一致。
- 改名 / 下线节点前先 grep 路由器 `/etc/openclash/custom/*.sh|*.lua` 有没有硬编码该名字。
- `clash_meta -t` 校验必须过；但运行态文件含 `external-ui` 绝对路径，需按上面「独立目录」办法跑，别直接 `-d /etc/openclash`。
- 令牌轮换会立即失效旧链接——轮换后同步更新本机链接文件与所有客户端。
- 若 `mihomo -t` 失败或结构自检报错：**不要**强行发布，先修模板（生成器会保留旧版）。
