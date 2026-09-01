#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

compare_copies() { # ROOT
  local root="$1" source render canonical="$1/skills/orch/scripts/lib/kendex-env.sh" count=0
  for source in "$root"/skills/*/scripts/lib/kendex-env.sh; do
    count=$((count + 1))
    cmp -s "$canonical" "$source" || {
      echo "${source#"$root/"} differs from skills/orch/scripts/lib/kendex-env.sh" >&2
      return 1
    }
    render="$root/.agents/${source#"$root/"}"
    cmp -s "$source" "$render" || {
      echo "${render#"$root/"} differs from its source" >&2
      return 1
    }
  done
  [[ $count -eq 6 ]] || { echo "expected six kendex-env.sh copies, found $count" >&2; return 1; }
}

compare_copies "$ROOT"
for source in "$ROOT"/skills/*/scripts/lib/kendex-env.sh; do
  rel="${source#"$ROOT/"}"
  mkdir -p "$SCRATCH/${rel%/*}" "$SCRATCH/.agents/${rel%/*}"
  cp "$source" "$SCRATCH/$rel"
  cp "$ROOT/.agents/$rel" "$SCRATCH/.agents/$rel"
done
printf '\n# planted divergence\n' >> "$SCRATCH/skills/worktree/scripts/lib/kendex-env.sh"
if compare_copies "$SCRATCH" >/dev/null 2>&1; then
  echo "vendored-settings-libs: planted divergence passed" >&2
  exit 1
fi
echo "vendored-settings-libs: six copies and renders match"
