#!/usr/bin/env bash
# redact-scan.sh — 提交前脱敏扫描。详见 redact-scan.py 头部说明。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY=$(command -v python3 || command -v python || true)
[ -n "$PY" ] || { echo "需要 python3" >&2; exit 2; }
exec "$PY" "$HERE/redact-scan.py" "$@"
