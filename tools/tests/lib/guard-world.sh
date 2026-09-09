#!/usr/bin/env bash
# The world every tools/guard suite starts from: a seeded repository that
# passes a guard run as it stands. It carries a demo skill with every render
# in step, a demo agent rendered to all three harness directories, a demo hook
# rendered to two of them (the real tree's hook sets differ), a hook test that
# renders nowhere, a temporary-fixture test that predates rooted(), and the
# directories tools/bash32-lint scans. A suite plants its own defects and comes
# back here with reset_world. Sourced after the suite's `set -euo pipefail`
# and git-variable preamble; what a suite reads from here:
#   R                        the world; GUARD, REPO, REAL_GIT, REAL_AWK, TMP
#   run_guard [VAR=VALUE...] guard in the world, --full under FULL_GUARD=1;
#                            sets OUT and RC
#   mutant_guard SED-EXPR    stage a guard copy with the edit applied; false
#                            when the edit changed nothing
#   run_mutant               the copy at commit time; sets OUT and RC
#   reset_world              the seeded commit, an empty index, a clean tree
#   ok / bad                 the tally in PASS and FAIL
# The fixture build below is unchecked line by line and stands on errexit.
set -euo pipefail

GUARD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$GUARD_LIB_DIR/../../.." && pwd)"
GUARD="$REPO/tools/guard"
REAL_GIT="$(command -v git)"
REAL_AWK="$(command -v awk)"
TMP="$(mktemp -d)" || { echo "guard-world: mktemp -d failed" >&2; exit 1; }
mkdir -p "$TMP/nohooks"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

R="$TMP/repo"
mkdir -p "$R/.claude" "$R/tools"
mkdir -p "$R/crates/core/tests"
git -C "$R" init -q
git -C "$R" symbolic-ref HEAD refs/heads/main
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
printf '[]\n' >"$R/.kendex-generated.json"
git -C "$R" config core.hooksPath "$TMP/nohooks"
printf '# fixture\n' >"$R/AGENTS.md"
cat >"$R/kendex.toml" <<'TOML'
schema = 6
[bot-instructions]
schema = 1
[bot-instructions.repo]
name = "fixture"
summary = "A repository for guard checks."
TOML
printf '%s\n' \
  'fn existing_fixture() {' \
  '    let tmp = tempfile::tempdir().unwrap();' \
  '    drop(tmp);' \
  '}' >"$R/crates/core/tests/existing_temp.rs"
# The bash32-lint lane runs on every pass and resolves its exception entries
# and its hand-named roster entries against the repository it runs in, so the
# fixture derives each rather than copying a list that goes stale with it. An
# exception directory holds no shell file; a roster one dies without one.
# -E on the exception read, because `\|` alternation inside `\(...\)` is a GNU
# BRE extension: BSD sed reads it as a literal bar, so the loop below creates
# no exception directory and every guard pass dies in the bash32-lint lane.
while IFS= read -r e; do
  mkdir -p "$R/$e" && printf 'not shell\n' >"$R/$e/README.md"
done < <(sed -nE 's#^NO_(SCAN|SHELL)="(.*)"$#\2#p' "$REPO/tools/bash32-lint" | tr ' ' '\n' | grep .)
while IFS= read -r e; do
  mkdir -p "$R/$e" && printf '#!/usr/bin/env bash\necho rostered\n' >"$R/$e/rostered.sh"
done < <(sed -n 's#^  set -- \(.*\)$#\1#p' "$REPO/tools/bash32-lint" | tr ' ' '\n' | grep -v '[*]')
mkdir -p "$R/skills/demo/scripts" "$R/skills/demo/tests" \
  "$R/.agents/skills/demo/scripts" "$R/.agents/skills/demo/tests" \
  "$R/agents" "$R/.claude/agents" "$R/.codex/agents" "$R/.pi/agents"
printf '#!/usr/bin/env bash\necho demo\n' >"$R/skills/demo/scripts/demo.sh"
printf '#!/usr/bin/env bash\necho tested\n' >"$R/skills/demo/tests/demo.test.sh"
printf '#!/usr/bin/env bash\necho accented\n' >"$R/skills/demo/scripts/frappé.sh"
cp "$R/skills/demo/scripts/demo.sh" "$R/.agents/skills/demo/scripts/demo.sh"
cp "$R/skills/demo/tests/demo.test.sh" "$R/.agents/skills/demo/tests/demo.test.sh"
cp "$R/skills/demo/scripts/frappé.sh" "$R/.agents/skills/demo/scripts/frappé.sh"
printf '# demo agent\n' >"$R/agents/demo.md"
printf '# demo agent render\n' >"$R/.claude/agents/demo.md"
printf 'name = "demo"\n' >"$R/.codex/agents/demo.toml"
printf '# demo agent render\n' >"$R/.pi/agents/demo.md"
mkdir -p "$R/hooks/tests" "$R/.claude/hooks" "$R/.codex/hooks" "$R/.pi/kendex/hooks"
printf '#!/usr/bin/env bash\necho hooked\n' >"$R/hooks/demo.sh"
printf '#!/usr/bin/env bash\necho hooked\n' >"$R/hooks/tests/demo.test.sh"
cp "$R/hooks/demo.sh" "$R/.claude/hooks/demo.sh"
cp "$R/hooks/demo.sh" "$R/.codex/hooks/demo.sh"
printf '#!/usr/bin/env bash\necho other\n' >"$R/.pi/kendex/hooks/other.sh"
# The command-safety policy lane reads the repository's own two policy
# sources; the world carries the real ones so every guard run has them.
mkdir -p "$R/docs/authoring"
cp "$REPO/kendex.settings.toml" "$R/kendex.settings.toml"
cp "$REPO/docs/authoring/command-safety.md" "$R/docs/authoring/command-safety.md"
git -C "$R" add -A
git -C "$R" commit -q -m fixture
SEED="$(git -C "$R" rev-parse HEAD)"

reset_world() { # — the seeded commit, an empty index and a clean tree
  git -C "$R" reset -q --hard "$SEED"
  git -C "$R" clean -qfd
}

run_guard() { # [VAR=VALUE...] — sets OUT and RC
  OUT=""
  RC=0
  args=()
  [ "${FULL_GUARD:-0}" -eq 0 ] || args+=(--full)
  OUT="$(cd "$R" && env "$@" "$GUARD" ${args[@]+"${args[@]}"} 2>&1 </dev/null)" || RC=$?
}

# A mutant is a copy of guard with one edit, run in place of it: it removes
# one check and expects the planted defect to pass, proving the red beside it
# came from that check and not from a neighbour. The copy sits beside a copy
# of bash32-lint and under a link to the package tree because guard resolves
# its sibling tools and the packages next to itself.
ln -s "$REPO/.agents" "$TMP/.agents"
MUTANT_TOOLS="$TMP/mutant-tools"
mkdir -p "$MUTANT_TOOLS"
cp "$REPO/tools/bash32-lint" "$MUTANT_TOOLS/bash32-lint"
mutant_guard() { # SED-EXPR — stage a guard copy with that edit applied
  sed "$1" "$GUARD" >"$MUTANT_TOOLS/guard"
  chmod +x "$MUTANT_TOOLS/guard"
  ! cmp -s "$GUARD" "$MUTANT_TOOLS/guard"
}
run_mutant() { # — sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$MUTANT_TOOLS/guard" 2>&1 </dev/null)" || RC=$?
}
