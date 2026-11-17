#!/usr/bin/env python3
"""redact-scan — 提交前扫描疑似敏感内容。

用法:
    redact-scan.sh              # 扫工作区（git 跟踪文件；无 git 时扫全树）
    redact-scan.sh --staged     # 只扫 git 暂存区内容（pre-commit 用）
    redact-scan.sh PATH ...     # 只扫指定文件/目录

退出码: 0 干净；1 命中；2 环境问题。

规则可扩展：把额外正则（每行一条）写进 $NODES_REDACT_EXTRA（默认 ~/.nodes-redact-extra.txt）。
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

# 文档示例里合法出现的地址，不算泄漏
ALLOW_IP = {
    "0.0.0.0", "127.0.0.1", "255.255.255.255", "1.1.1.1", "8.8.8.8", "8.8.4.4",
    "114.114.114.114", "192.0.2.1", "192.0.2.10", "198.51.100.1", "203.0.113.1",
    "169.254.169.254", "10.0.0.1", "172.16.0.1", "192.168.1.1",
}

RULES = [
    ("ipv4", re.compile(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])")),
    ("ipv6", re.compile(r"(?<![0-9a-zA-Z:])(?:[0-9a-fA-F]{1,4}:){4,}[0-9a-fA-F]{1,4}(?![0-9a-zA-Z:])")),
    ("uuid", re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")),
    ("private-key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("token-url", re.compile(r"/[A-Za-z0-9_-]{16,}/sub\.ya?ml")),
    ("long-b64", re.compile(r"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{43,}={0,2}(?![A-Za-z0-9+/=])")),
    ("cf-token", re.compile(r"\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}")),
]

# RFC 5737 文档示例段：整段放过
ALLOW_NETS = ("192.0.2.", "198.51.100.", "203.0.113.")

SKIP_DIRS = {".git", ".cache", "node_modules", "__pycache__", ".venv", "venv"}
# 私有面默认不扫（它本来就不上传）；--all 才一起扫
PRIVATE_DIRS = {"private"}
SKIP_EXT = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf", ".zip", ".gz",
            ".tar", ".tgz", ".sqlite", ".sqlite3", ".db", ".woff", ".woff2", ".ttf"}


def is_text(path: str) -> bool:
    ext = os.path.splitext(path)[1].lower()
    if ext in SKIP_EXT:
        return False
    try:
        with open(path, "rb") as fh:
            return b"\x00" not in fh.read(4096)
    except OSError:
        return False


def iter_worktree(base: str, skip_private: bool = True):
    for root, dirs, files in os.walk(base):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS
                   and not (skip_private and d in PRIVATE_DIRS)]
        for f in files:
            p = os.path.join(root, f)
            if is_text(p):
                yield p


def git_files(base: str):
    """返回 git 跟踪的文本文件列表；不是 git 仓时返回 None（调用方回退到全树扫描）。"""
    try:
        out = subprocess.run(["git", "-C", base, "ls-files", "-z"],
                             capture_output=True, check=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    files = []
    for name in out.split(b"\x00"):
        if not name:
            continue
        p = os.path.join(base, name.decode("utf-8", "replace"))
        if os.path.isfile(p) and is_text(p):
            files.append(p)
    return files


def iter_staged(base: str):
    try:
        names = subprocess.run(["git", "-C", base, "diff", "--cached", "--name-only", "--diff-filter=ACM", "-z"],
                               capture_output=True, check=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return
    for name in names.split(b"\x00"):
        if not name:
            continue
        rel = name.decode("utf-8", "replace")
        try:
            blob = subprocess.run(["git", "-C", base, "show", f":{rel}"],
                                  capture_output=True, check=True).stdout
        except subprocess.CalledProcessError:
            continue
        yield rel, blob


def extra_rules():
    path = os.environ.get("NODES_REDACT_EXTRA", os.path.expanduser("~/.nodes-redact-extra.txt"))
    rules = []
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#"):
                    try:
                        rules.append(("extra", re.compile(line)))
                    except re.error as exc:
                        print(f"!! 额外规则无效，忽略: {line} ({exc})", file=sys.stderr)
    return rules


def check_text(rel: str, text: str, rules) -> list[str]:
    hits = []
    for lineno, line in enumerate(text.splitlines(), 1):
        if line.startswith(("    ", "\t")) and line.lstrip().startswith("#"):
            pass  # 注释照样扫，凭据藏在注释里更危险
        for name, rx in rules:
            for m in rx.finditer(line):
                frag = m.group(0)
                if name == "ipv4":
                    octets = frag.split(".")
                    if len(octets) != 4 or any(int(o) > 255 for o in octets if o.isdigit()):
                        continue
                    if frag in ALLOW_IP or frag.startswith(ALLOW_NETS):
                        continue
                if name == "long-b64":
                    # 纯 hex 摘要、全字母单词不算
                    if re.fullmatch(r"[0-9a-fA-F]+", frag) or re.fullmatch(r"[A-Za-z]+", frag):
                        continue
                hits.append(f"{rel}:{lineno}: [{name}] {frag[:80]}")
    return hits


def main(argv: list[str]) -> int:
    base = os.environ.get("NODES_ROOT") or os.getcwd()
    rules = RULES + extra_rules()
    hits: list[str] = []
    skip_private = "--all" not in argv

    if "--staged" in argv:
        for rel, blob in iter_staged(base):
            hits += check_text(rel, blob.decode("utf-8", "replace"), rules)
    else:
        paths = [a for a in argv if not a.startswith("-")]
        if paths:
            files = []
            for p in paths:
                if os.path.isdir(p):
                    files += list(iter_worktree(os.path.abspath(p), skip_private))
                else:
                    files.append(p)
        else:
            tracked = git_files(base)
            if tracked is not None and skip_private:
                tracked = [f for f in tracked if not f.startswith(os.path.join(base, "private") + os.sep)]
            files = tracked if tracked is not None else list(iter_worktree(base, skip_private))
        for p in files:
            try:
                with open(p, encoding="utf-8", errors="replace") as fh:
                    text = fh.read()
            except OSError:
                continue
            rel = os.path.relpath(p, base) if os.path.isabs(p) else p
            hits += check_text(rel, text, rules)

    if hits:
        print(f"✗ 脱敏扫描命中 {len(hits)} 处：", file=sys.stderr)
        for h in hits:
            print("  " + h, file=sys.stderr)
        print("\n确认每一处都属于公开内容（占位符/示例段地址/文档示例），再提交。", file=sys.stderr)
        return 1
    print("✓ 脱敏扫描干净")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
