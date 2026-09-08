#!/usr/bin/env bash
# The mkdir fallback reports the held lock and the elapsed wait limit.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/bin" "$SCRATCH/held.lock.d"
ln -s "$(command -v mkdir)" "$SCRATCH/bin/mkdir"
rc=0
PATH="$SCRATCH/bin" /bin/bash -c 'source "$1"; orch_take_lock 200 "$2" 0' bash \
  "$ROOT/skills/orch/scripts/lib/file-lock.sh" "$SCRATCH/held.lock" >"$SCRATCH/out" 2>"$SCRATCH/err" || rc=$?
[[ "$rc" -eq 1 && ! -s "$SCRATCH/out" ]]
[[ "$(sed -n '1p' "$SCRATCH/err")" == "file-lock: lock-timeout lock-file=$SCRATCH/held.lock wait-s=0" ]]
printf 'file-lock messages: pass\n'
