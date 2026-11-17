#!/usr/bin/env bash
# status.sh — 一眼看两边有没有未提交改动。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
for repo in . private; do
  [ -d "$repo/.git" ] || { echo "== $repo: 还不是 git 仓"; continue; }
  name=$([ "$repo" = . ] && echo "工作流面" || echo "节点面")
  echo "== $name ($repo)"
  git -C "$repo" status --short --branch | sed 's/^/   /'
  git -C "$repo" log -1 --format='   最近: %h %s (%cr)' 2>/dev/null || true
done
