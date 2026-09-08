#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

compare_copies() { # ROOT
  local root="$1" source render canonical="$1/skills/orch/scripts/lib/kendex-env.sh" has_canonical=0
  local -a sources=("$root"/skills/*/scripts/lib/kendex-env.sh)
  # The expected set is the glob's own, never a count kept here: a skill
  # vendoring the lib joins the scan by existing. Under-inclusion is closed by
  # the floor (an unmatched glob is its own pattern, one entry) and by the one
  # required member, the copy every other is compared against; either failing
  # is a broken scan, not a sparse tree. Over-inclusion stays open: an extra
  # match is compared like the rest.
  for source in "${sources[@]}"; do
    [[ $source != "$canonical" ]] || has_canonical=1
  done
  [[ ${#sources[@]} -ge 2 ]] || {
    echo "skills/*/scripts/lib/kendex-env.sh matched ${#sources[@]} entry: the glob is broken" >&2
    return 1
  }
  [[ $has_canonical -eq 1 ]] || {
    echo "skills/*/scripts/lib/kendex-env.sh missed skills/orch/scripts/lib/kendex-env.sh: the glob is broken" >&2
    return 1
  }
  for source in "${sources[@]}"; do
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
echo "vendored-settings-libs: every copy and its render match"
