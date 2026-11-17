#!/usr/bin/env bash
# sync.sh — 提交工作流面或节点面。用法: ./sync.sh wf "msg" | ./sync.sh ops "msg"
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
target="${1:-}"; msg="${2:-}"
case "$target" in
  wf)  git add -A && git commit -m "${msg:-chore: update workflow}" ;;
  ops) git -C private add -A && git -C private commit -m "${msg:-chore: update nodes}" ;;
  *)   echo "用法: $0 wf|ops \"提交说明\"" >&2; exit 2 ;;
esac
