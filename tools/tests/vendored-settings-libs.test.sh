#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

compare_copies() { # ROOT
  local root="$1" source render canonical="$1/skills/orch/scripts/lib/kendex-env.sh" has_canonical=0
  local -a sources=("$root"/skills/*/scripts/lib/kendex-env.sh)
  # The expected set is the glob's own, never a count kept here: a skill
  # vendoring the lib joins the scan by existing. The floor (an unmatched glob
  # is its own pattern, one entry) and the one required member, the copy every
  # other is compared against, close a broken extractor only; either failing
  # is a broken scan, not a sparse tree. Two directions stay open: a copy
  # deleted from the tree leaves the scan green, and an extra match is
  # compared like the rest.
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
# Each extractor guard has its own plant, asserting the diagnosis only that
# guard prints: on these worlds the comparison against a missing canonical
# would red as well, so the verdict alone would not prove the guard.
mkdir -p "$SCRATCH/unmatched/skills/none"
if diag="$(compare_copies "$SCRATCH/unmatched" 2>&1)" || [[ $diag != *"matched 1 entry: the glob is broken"* ]]; then
  echo "vendored-settings-libs: an unmatched glob was not named as broken: $diag" >&2
  exit 1
fi
mkdir -p "$SCRATCH/no-orch"
cp -R "$SCRATCH/skills" "$SCRATCH/.agents" "$SCRATCH/no-orch/"
rm -f "$SCRATCH/no-orch/skills/orch/scripts/lib/kendex-env.sh" "$SCRATCH/no-orch/.agents/skills/orch/scripts/lib/kendex-env.sh"
if diag="$(compare_copies "$SCRATCH/no-orch" 2>&1)" || [[ $diag != *"missed skills/orch/scripts/lib/kendex-env.sh: the glob is broken"* ]]; then
  echo "vendored-settings-libs: a missing canonical copy was not named as broken: $diag" >&2
  exit 1
fi
# The derived set is what this scan buys over a kept count: an eighth skill
# vendoring the lib joins by existing. The plant plays that skill, and a scan
# restricted to the seven present today reds here.
mkdir -p "$SCRATCH/eighth"
for source in "$ROOT"/skills/*/scripts/lib/kendex-env.sh; do
  rel="${source#"$ROOT/"}"
  mkdir -p "$SCRATCH/eighth/${rel%/*}" "$SCRATCH/eighth/.agents/${rel%/*}"
  cp "$source" "$SCRATCH/eighth/$rel"
  cp "$ROOT/.agents/$rel" "$SCRATCH/eighth/.agents/$rel"
done
mkdir -p "$SCRATCH/eighth/skills/newcomer/scripts/lib" "$SCRATCH/eighth/.agents/skills/newcomer/scripts/lib"
cp "$ROOT/skills/orch/scripts/lib/kendex-env.sh" "$SCRATCH/eighth/skills/newcomer/scripts/lib/kendex-env.sh"
cp "$ROOT/skills/orch/scripts/lib/kendex-env.sh" "$SCRATCH/eighth/.agents/skills/newcomer/scripts/lib/kendex-env.sh"
if ! diag="$(compare_copies "$SCRATCH/eighth" 2>&1)"; then
  echo "vendored-settings-libs: a skill vendoring an eighth copy was refused: $diag" >&2
  exit 1
fi
echo "vendored-settings-libs: every copy and its render match"
