#!/usr/bin/env bash
# Catalog authors produce decision citations in shipped markdown. This suite
# exercises tools/guard, including the must-fail control for its link rule.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/guard-world.sh
. "$TEST_DIR/lib/guard-world.sh"

# The shared runner accepts explicit environment options before its bounds.
GUARD_TEST_ENV=(-i "PATH=$PATH" "HOME=$TMP" LC_ALL=C)
git -C "$R" config gc.auto 0
git -C "$R" config maintenance.auto false

while IFS='|' read -r expected path content; do
  reset_world
  mkdir -p -- "$R/$(dirname -- "$path")"
  printf '%b\n' "$content" >"$R/$path"
  git -C "$R" add -- "$path"
  # Test the whole-tree prose scan without arming the separate render lane.
  git -C "$R" commit -qm fixture
  run_guard
  case "$expected" in
    refuse)
      [ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: shipped-decision-link=$path"* ]] \
        && [[ "$OUT" == *$'D\t'"$path"$'\t'* ]] \
        && ok "bare decision: $path $content" \
        || bad "bare decision: $path $content" "rc=$RC out=$OUT" ;;
    pass)
      [ "$RC" -eq 0 ] && ok "not a bare shipped citation: $path $content" \
        || bad "not a bare shipped citation: $path $content" "rc=$RC out=$OUT" ;;
    scan)
      [ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: shipped-decision-scan=$path"* ]] \
        && ok "unreadable block structure refuses: $path" \
        || bad "unreadable block structure refuses: $path" "rc=$RC out=$OUT" ;;
    *) bad "unknown test expectation" "$expected" ;;
  esac
done <<'CASES'
refuse|skills/demo/README.md|D016
refuse|agents/citation.md|Read (D1).
refuse|hooks/citation.md|D12345, then D016.
refuse|skills/demo/README.md|# D016
refuse|skills/demo/README.md|text\tD016
refuse|skills/demo/README.md|`D016` and D1
refuse|skills/demo/README.md|[D016](broken
refuse|skills/demo/README.md|\\[D016](https://example.com/D016)
refuse|skills/demo/README.md|<div>[D016](https://example.com/D016)</div>
refuse|skills/demo/README.md|<div>\n[D016](https://example.com/D016)\n</div>
refuse|skills/demo/README.md|> D016
pass|skills/demo/README.md|[D016](https://github.com/vanillagreencom/kendex/blob/main/docs/decisions/D016-merge-route-reads-bypass.md)
pass|skills/demo/README.md|[D016](<https://example.com/D016> "D016")
pass|skills/demo/README.md|[D016](https://example.com/(D016))
pass|skills/demo/README.md|[text]() then [D016](https://example.com/D016)
pass|skills/demo/README.md|\\\\[D016](https://example.com/D016)
pass|skills/demo/README.md|`\\[D016](https://example.com/D016)`
pass|skills/demo/README.md|AD016 D016x 1D016 D016A DXXX
pass|skills/demo/README.md|`D016` and ``D1 ` D2``
pass|skills/demo/README.md|```text\nD016\n```
pass|skills/demo/README.md|~~~text\nD016\n~~~
pass|skills/demo/README.md|> ```text\n> D016\n> ```
pass|skills/demo/tests/citation.md|D016
pass|agents/tests/citation.md|D016
pass|hooks/tests/citation.md|D016
pass|skills/demo/AGENTS.md|D016
pass|skills/demo/DEVELOPMENT.md|D016
pass|skills/demo/evals/citation.md|D016
refuse|skills/demo/templates/DEVELOPMENT.md|D016
refuse|agents/DEVELOPMENT.md|D016
refuse|hooks/DEVELOPMENT.md|D016
pass|docs/citation.md|D016
pass|skills/demo/citation.txt|D016
scan|skills/demo/README.md|```text\nD016
CASES

while IFS= read -r content; do
  reset_world
  # docs-writing/templates/DEVELOPMENT.md is catalog content, unlike the
  # skill's top-level maintainer notes. Stage its source and render together.
  mkdir -p "$R/skills/demo/templates" "$R/.agents/skills/demo/templates"
  printf '# citation\n\n%b\n' "$content" >"$R/skills/demo/templates/DEVELOPMENT.md"
  cp "$R/skills/demo/templates/DEVELOPMENT.md" "$R/.agents/skills/demo/templates/DEVELOPMENT.md"
  git -C "$R" add -- skills/demo/templates/DEVELOPMENT.md .agents/skills/demo/templates/DEVELOPMENT.md
  run_guard
  [ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: shipped-decision-link=skills/demo/templates/DEVELOPMENT.md"* ]] \
    && [[ "$OUT" == *$'D\tskills/demo/templates/DEVELOPMENT.md\t3\tD016'* ]] \
    && ok "must-fail fixture reaches the decision-link rule with its source line: $content" \
    || bad "must-fail fixture reaches the decision-link rule with its source line: $content" "rc=$RC out=$OUT"
  # Keep extraction and matched text intact. Remove only the refusal behavior.
  matches=$(grep -Fc 'say shipped-decision-link "$f"' "$GUARD") || matches=0
  if [ "$matches" -eq 1 ] && mutant_guard 's/say shipped-decision-link "$f"/: # decision-link control/'; then
    run_mutant
    [ "$RC" -eq 0 ] && [[ "$OUT" == *$'D\tskills/demo/templates/DEVELOPMENT.md\t3\tD016'* ]] \
      && ok "control: the same fixture passes when the link refusal is disabled: $content" \
      || bad "control: the same fixture passes when the link refusal is disabled: $content" "rc=$RC out=$OUT"
  else
    bad "control: the decision-link refusal was not changed in the guard copy"
  fi
done <<'CASES'
Read D016.
\\[D016](https://example.com/D016)
<div>[D016](https://example.com/D016)</div>
CASES

echo "=== incomplete common-file discovery refuses all dependent scans ==="
reset_world
printf '#!/usr/bin/env bash\nif [ "$*" = "$GUARD_TEST_FAIL_COLLECTION" ]; then echo skills/demo/README.md; exit 9; fi\nexec %q "$@"\n' \
  "$REAL_GIT" >"$MUTANT_TOOLS/git"
chmod +x "$MUTANT_TOOLS/git"
for command in 'ls-files' 'diff --cached --name-only'; do
  GUARD_TEST_ENV=(-i "PATH=$MUTANT_TOOLS:$PATH" "HOME=$TMP" LC_ALL=C "GUARD_TEST_FAIL_COLLECTION=$command")
  run_guard
  [ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: file-set=unreadable"* ]] \
    && ok "a failed $command cannot pass on its partial output" \
    || bad "a failed $command cannot pass on its partial output" "rc=$RC out=$OUT"
  matches=$(grep -Fc 'say file-set unreadable' "$GUARD") || matches=0
  if [ "$matches" -eq 1 ] && mutant_guard 's/say file-set unreadable/:/'; then
    run_mutant
    [ "$RC" -eq 0 ] && ok "control: without the file-set refusal a failed $command passes" \
      || bad "control: without the file-set refusal a failed $command passes" "rc=$RC out=$OUT"
  else
    bad "control: the file-set refusal was not changed in the guard copy"
  fi
done

printf '\n=== %s passed, %s failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
