---
name: routing-change
description: 改代理分流规则或切换生产出口（软路由 OpenClash / 客户端）时使用——含备份、生效验证、回滚与排障固定动作，避免改坏全家网络。
---

# 分流变更与生产切换

适用于：给某类流量换出口、新增/修改域名规则、切换订阅、停用旧配置。
**这是会断全家网的操作**，按下面顺序做，不许跳步。

## 固定动作（五步）

1. **备份**：`<router>:/mnt/sda4/backup/<用途>-<时间戳>/` 下存 uci 配置、运行配置、被改脚本、crontab，并写 `README-rollback.txt`。
2. **说清语义**：这次改什么、什么流量受影响、预期出口是谁（一句话）。
3. **改**：规则只改云上模板（`subscription-ops`）；组选择用 API PUT；路由器订阅文件改动**落盘 + API 热加载**（`PUT /configs?force=true`，见 `subscription-ops`）——**只有端口/DNS/防火墙/TUN 类改动才 `restart`**。
4. **真实验证**：
   - `/proxies` 看组员与 `now`；`/rules` 抽查规则指向；
   - 真实请求看**出口 IP**（`icanhazip` / `chatgpt.com/cdn-cgi/trace`）；
   - 家宽连通性抽查（baidu / YouTube / 目标域）；
   - 热加载场景：`pidof clash` 的 pid **不变** = 成功（换了进程说明还在 restart 路径）。
5. **留痕**：在 `<nodes-root>/_ops/docs/变更记录.md` 追加一条（含备份路径与回滚命令）。

## 必须知道的排障判据

- **客户端日志里的 `IP:` 字段**是最快的定位手段：它直接告诉你是哪个出口被目标站拦了。
  （桌面端 AI 客户端「掉登录」= `/wham/usage`、`/websites` 等接口 403，页面里带 `IP:<出口>`。）
- **CF `cf-mitigated: challenge`**：curl 拿到属正常（浏览器能过）；真问题是浏览器也循环——那才是 IP 信誉问题，换组验证。
- **组被莫名改动**：先看 `tail /tmp/openclash_auto_select.log`——它（cron */5）应只巡检不切组；出现主动改 AI/YouTube 即异常；再核对 `crontab -l` 里 failover（*/2）与两个脚本的运行日志。
- **`store-selected`**：组选择会被持久化。你手动改的才是"对的"，脚本改的要看意图（踩过这个坑：手动选择被自动脚本覆盖）。
- **路由器重启 OpenClash**（仅限必须 restart 的改动）后要等 10–15 秒再验证，`/etc/init.d/openclash status` 显示 running 且进程在跑新配置；订阅类改动一律走热加载，避免冷启动窗口（fake-ip/DNS 未就绪时兜底可能把流量甩到非预期出口）。

## 常见目标出口（按需替换成本机口径）

| 流量 | 出口 |
|---|---|
| AI 家族 | `AI` 组（显式名单，通常只放主力大流量机 + 其 CF 救援形态） |
| YouTube | `YouTube` 组（默认 `YouTube-Auto`，按延迟自动挑，排除低带宽机） |
| 普通境外（Google/TG/微软等） | `Proxy` 组（默认 `Proxy-Auto`，全部自建形态自动挑最低延迟） |
| 未匹配境外 UDP | `AI` 组（域名可识别的仍按域名规则） |
| 国内 | 直连（`GEOSITE,cn` + `GEOIP,CN,no-resolve`） |
| 兜底 | `AI`（分类失败的流量也只走主力机，不漏直出） |

## 回滚

- 订阅切换：还原 uci `config_path` + 订阅文件 + 覆写脚本 + crontab → `restart`（备份 README 五步）。
- 单条规则：改回模板 → 重新生成 → 重下订阅 → **热加载**（必须 restart 的场景才 restart）。
- 任何一步失败：**停下、保留现场**、把现象写进变更记录，不要连环重试。
