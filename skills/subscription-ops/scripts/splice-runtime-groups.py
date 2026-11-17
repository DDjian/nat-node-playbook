#!/usr/bin/env python3
"""把订阅里的 proxies / proxy-groups 块套进 OpenClash 运行态配置（热加载用，2026-10-13 起）。

背景：软路由有两份文件——
  /etc/openclash/config/zijian.yaml  订阅原件（OpenClash 下次重启会用它重新生成运行态）
  /etc/openclash/zijian.yaml         运行态（OpenClash 重新序列化过：缩进/引号/sniffer/DNS 端口都不同）
改组（而不只是改规则行）时不能只改一份，否则重启后运行态会把旧组带回来。

用法（在软路由上跑）：
  scp skills/subscription-ops/scripts/splice-runtime-groups.py <router>:/tmp/
  ssh <router> 'python3 /tmp/splice-runtime-groups.py /tmp/zijian-new.yaml /etc/openclash/zijian.yaml'
  成功会生成 zijian.yaml.new：先 clash_meta -t 校验，再 mv 覆盖并 API 热加载。

注意：运行态里列表项是顶格的（- name: X），所以「下一个顶层键」判定必须排除 `- ` 开头的行，
否则块尾会判错、新旧组并存（2026-10-13 踩过：mihomo 报 duplicate group name）。
另：增减节点时 `proxies:` 块也要一起套（2026-10-13 踩过：只换组 → 被删的节点仍留在列表里）。
"""
import sys


def extract_block(lines, key):
    start = None
    for i, l in enumerate(lines):
        if l.rstrip() == key:
            start = i
            break
    if start is None:
        raise SystemExit("ERROR: 没找到 " + key)
    end = len(lines)
    for j in range(start + 1, len(lines)):
        s = lines[j]
        # 顶层键才算块尾；运行态文件里列表项是顶格的（"- xxx"），不能算
        if s.strip() and not s.startswith((" ", "\t", "#", "-")):
            end = j
            break
    return start, end


def dedent2(lines):
    # 订阅缩进 2 格、运行态 0 格；子列表多缩进也没问题（YAML 合法）
    return [l[2:] if l.startswith("  ") else l for l in lines]


def splice_key(rt_lines, sub_lines, key):
    s1, s2 = extract_block(sub_lines, key)
    r1, r2 = extract_block(rt_lines, key)
    return rt_lines[:r1] + [key] + dedent2(sub_lines[s1 + 1:s2]) + rt_lines[r2:], r1


def main():
    sub_path, rt_path = sys.argv[1], sys.argv[2]
    sub = open(sub_path, encoding="utf-8").read().splitlines()
    rt = open(rt_path, encoding="utf-8").read().splitlines()

    new, _ = splice_key(rt, sub, "proxies:")
    new, r1 = splice_key(new, sub, "proxy-groups:")
    text = "\n".join(new) + "\n"

    for need in ("Proxy-Auto", "YouTube-Auto", "type: url-test", "name: AI", "rules:"):
        if need not in text:
            raise SystemExit("ERROR: 结果缺少 " + need)
    if "{{" in text:
        raise SystemExit("ERROR: 结果含未替换占位符")

    names = [l.split("name:", 1)[1].strip() for l in new[r1 + 1:] if l.startswith("- name:")]
    if len(names) != len(set(names)):
        raise SystemExit("ERROR: 组名重复 " + str(names))
    if names[:1] != ["Proxy-Auto"]:
        raise SystemExit("ERROR: 组顺序异常 " + str(names))

    # 节点清单必须与订阅逐名一致（防只换组不换 proxies 导致删掉的节点残留）
    sp1, sp2 = extract_block(sub, "proxies:")
    sub_names = {l.split("name:", 1)[1].strip() for l in sub[sp1 + 1:sp2] if l.strip().startswith("- name:")}
    rt_names = {l.split("name:", 1)[1].strip() for l in new if l.startswith("- name:")}
    # 组名不算节点
    group_names = set(names)
    rt_node_names = rt_names - group_names
    if rt_node_names != sub_names:
        raise SystemExit("ERROR: 节点清单不一致; 多了 %s; 少了 %s"
                         % (sorted(rt_node_names - sub_names), sorted(sub_names - rt_node_names)))

    open(rt_path + ".new", "w", encoding="utf-8").write(text)
    print("组:" + ",".join(names) + f"（{len(names)} 个）")
    print("节点:" + ",".join(sorted(sub_names)))
    print(f"OK: 运行态 {len(new)} 行（原 {len(rt)} 行），输出 {rt_path}.new")


if __name__ == "__main__":
    main()
