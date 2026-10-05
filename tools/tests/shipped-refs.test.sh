#!/usr/bin/env bash
# The proof for tools/shipped-refs: a catalog of three skills (alpha
# requiring beta, gamma optional, alpha shipping one decision record), a hook,
# an agent and two Pi packages, one whose package.json `files` list names less
# than kendex's install copies, so its unlisted files show the list narrows
# nothing. Each row plants one file and runs the real script over the fixture,
# reading its exit status and keyed first line; the controls run edited copies
# of the script, one per rule.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO/tools/shipped-refs"
TMP_ROOT="$(mktemp -d)" || { echo "shipped-refs.test: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "shipped-refs.test: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "shipped-refs.test: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

W="$TMP_ROOT/repo"
mkdir -p "$W/skills/alpha/docs" "$W/skills/beta" "$W/skills/gamma" "$W/hooks" "$W/agents" \
  "$W/pi-extensions/pi-demo/extensions" "$W/pi-extensions/pi-other"
git -C "$W" init -q
git -C "$W" config user.email test@example.com
git -C "$W" config user.name test
git -C "$W" config gc.auto 0
git -C "$W" config maintenance.auto false
printf -- '---\nname: alpha\ndependencies:\n  required: [beta]\n  optional: [gamma]\n---\n\n# Alpha\n\n## Usage\n' >"$W/skills/alpha/SKILL.md"
printf -- '---\nname: beta\n---\n\n# Beta\n\n## Usage\n' >"$W/skills/beta/SKILL.md"
printf -- '---\nname: gamma\n---\n\n# Gamma\n\n## Usage\n' >"$W/skills/gamma/SKILL.md"
printf '# Shipped rule\n' >"$W/skills/alpha/docs/D021-shipped-rule.md"
printf '#!/usr/bin/env bash\necho hooked\n' >"$W/hooks/demo.sh"
printf -- '---\nname: demo\n---\n\n# Demo\n' >"$W/agents/demo.md"
printf '{"files": ["extensions/", "README.md", "package.json"]}\n' >"$W/pi-extensions/pi-demo/package.json"
printf 'export {};\n' >"$W/pi-extensions/pi-demo/extensions/index.ts"
printf '{"name": "pi-other"}\n' >"$W/pi-extensions/pi-other/package.json"
git -C "$W" add -A
git -C "$W" commit -qm seed
SEED="$(git -C "$W" rev-parse HEAD)"

reset_world() {
  git -C "$W" reset -q --hard "$SEED"
  git -C "$W" clean -qfdx
}
plant() { # PATH CONTENT — CONTENT read through printf %b
  mkdir -p -- "$W/$(dirname -- "$1")"
  printf '%b\n' "$2" >"$W/$1"
  git -C "$W" add -- "$1"
}
run() { # [SCRIPT] — sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$W" && env -i "PATH=$PATH" "HOME=$TMP_ROOT" LC_ALL=C "${1:-$SCRIPT}" tests evals DEVELOPMENT.md 2>&1 </dev/null)" || RC=$?
}

# A mutant is a copy of the script with one edit, beside a link to the
# package tree it resolves its libraries from.
ln -s "$REPO/.agents" "$TMP_ROOT/.agents"
mkdir -p "$TMP_ROOT/tools"
ln -s "$REPO/tools/lib" "$TMP_ROOT/tools/lib"
MUTANT="$TMP_ROOT/tools/shipped-refs"
mutant() { # FIXED-TEXT SED-EXPR — false unless the text occurs once and the edit changed the copy
  local matches
  matches=$(grep -Fc -- "$1" "$SCRIPT") || matches=0
  [ "$matches" -eq 1 ] || return 1
  sed "$2" "$SCRIPT" >"$MUTANT"
  chmod +x "$MUTANT"
  ! cmp -s "$SCRIPT" "$MUTANT"
}

echo "=== rows ==="
while IFS='|' read -r expected path content; do
  reset_world
  plant "$path" "$content"
  run
  label="$expected: $path $content"
  case "$expected" in
    decision)
      [ "$RC" -eq 1 ] && [[ "$OUT" == "shipped-refs: decisions="* ]] && [[ "$OUT" == *$'\n'"  $path:"[0-9]*$'\tD0'* ]] \
        && ok "$label" || bad "$label" "rc=$RC out=$OUT" ;;
    link)
      [ "$RC" -eq 1 ] && [[ "$OUT" == *"shipped-refs: links=1"* ]] && [[ "$OUT" == *$'\n'"  $path:"[0-9]*$'\t'* ]] \
        && [[ "$OUT" != *"decisions="* ]] && ok "$label" || bad "$label" "rc=$RC out=$OUT" ;;
    pass)
      [ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "$label" || bad "$label" "rc=$RC out=$OUT" ;;
    unreadable)
      [ "$RC" -eq 2 ] && [[ "$OUT" == "shipped-refs: unreadable=$path"* ]] \
        && ok "$label" || bad "$label" "rc=$RC out=$OUT" ;;
    *) bad "unknown row expectation" "$expected" ;;
  esac
done <<'ROWS'
decision|skills/alpha/README.md|Per D016 the route holds.
decision|skills/alpha/README.md|# D016
decision|skills/alpha/README.md|> D016
decision|skills/alpha/README.md|<div>D016</div>
decision|skills/alpha/README.md|[D016](https://github.com/vanillagreencom/kendex/blob/main/docs/decisions/D016-merge-route.md)
decision|skills/alpha/README.md|D12345 and D016.
decision|skills/alpha/templates/DEVELOPMENT.md|D016
decision|skills/beta/README.md|D021 ships with alpha, not beta.
decision|agents/demo.md|Read (D016).
decision|pi-extensions/pi-demo/README.md|D016
decision|pi-extensions/pi-other/DEVELOPMENT.md|D016
decision|skills/alpha/scripts/rule.sh|#!/usr/bin/env bash\n# D015 § D015: the rule\necho rule
decision|skills/alpha/scripts/rule|#!/usr/bin/env bash\n# REVISIT(D015): a usage field\necho rule
decision|skills/alpha/scripts/rule.py|# per D007\nprint(1)
decision|hooks/demo.sh|#!/usr/bin/env bash\n# under D002's handoff\necho hooked
decision|pi-extensions/pi-demo/extensions/index.ts|// per D015\nexport {};
pass|skills/alpha/README.md|`D016` names an example ID.
pass|skills/alpha/README.md|```text\nD016\n```
pass|skills/alpha/README.md|AD016 D016x 1D016 D16 DXXX
pass|skills/alpha/README.md|D021 ships beside this file.
pass|skills/alpha/tests/case.md|D016
pass|skills/alpha/tests/case.sh|# D016
pass|skills/alpha/DEVELOPMENT.md|D016
pass|skills/alpha/evals/case.md|D016
pass|skills/AGENTS.md|D016
pass|hooks/README.md|D016
pass|docs/notes.md|D016
decision|pi-extensions/pi-demo/DEVELOPMENT.md|D016
decision|pi-extensions/pi-demo/tests/case.md|D016
pass|pi-extensions/pi-demo/node_modules/dep/README.md|D016
pass|pi-extensions/pi-demo/extensions/coverage/report.md|D016
pass|skills/alpha/scripts/rule.sh|#!/usr/bin/env bash\necho "decisions get D017"
pass|skills/alpha/data.json|{"decision_ref": "D017"}
link|skills/alpha/README.md|[optional](../gamma/SKILL.md)
link|skills/alpha/README.md|[undeclared](../delta/SKILL.md)
link|skills/alpha/README.md|[repo](../../docs/notes.md)
link|skills/alpha/README.md|[above](../../../outside.md)
link|skills/alpha/README.md|[optional]: ../gamma/SKILL.md
link|skills/alpha/workflows/run.md|[section](../../gamma/SKILL.md#usage) § Usage
link|skills/beta/README.md|[back](../alpha/SKILL.md)
link|agents/demo.md|[skill](../skills/beta/SKILL.md)
link|pi-extensions/pi-demo/README.md|[sibling](../pi-other/README.md)
link|pi-extensions/pi-demo/DEVELOPMENT.md|[sibling](../pi-other/README.md)
link|skills/alpha/README.md|## [optional](../gamma/SKILL.md)
link|skills/alpha/README.md|The [optional](../gamma/SKILL.md) one\n===
pass|skills/alpha/README.md|[own](scripts/run.md) and [anchor](#usage)
pass|skills/alpha/README.md|[required](../beta/SKILL.md#usage)
pass|skills/alpha/workflows/run.md|[required](../../beta/SKILL.md) and [root](../)
pass|skills/alpha/README.md|[web](https://example.com/x.md) and `../gamma/SKILL.md`
pass|skills/alpha/tests/case.md|[optional](../../gamma/SKILL.md)
pass|skills/alpha/README.md|## [required](../beta/SKILL.md)
pass|pi-extensions/pi-demo/build/notes.md|[sibling](../../pi-other/README.md)
unreadable|skills/alpha/README.md|```text\nD016
unreadable|skills/alpha/scripts/rule.sh|#!/usr/bin/env bash\n# D015\necho "open
ROWS

echo "=== the manifest the link rule reads ==="
# A required list tools/lib/skill-requirements.awk cannot take refuses rather
# than reading as empty, as tools/ci-job-set refuses it.
while IFS='|' read -r label required; do
  reset_world
  plant skills/alpha/SKILL.md "---\nname: alpha\ndependencies:\n  required:$required\n---\n\n# Alpha"
  plant skills/alpha/README.md '[required](../beta/SKILL.md)'
  run
  [ "$RC" -eq 2 ] && [[ "$OUT" == "shipped-refs: manifest=skills/alpha/SKILL.md"* ]] \
    && ok "a $label required list refuses" || bad "a $label required list refuses" "rc=$RC out=$OUT"
done <<'ROWS'
block|\n    - beta
quoted-name| ["beta"]
ROWS
if mutant '[ -z "$manifest" ] || refuse manifest' 's/\[ -z "\$manifest" \] || refuse manifest/[ -z "$manifest" ] || : manifest/'; then
  run "$MUTANT"
  [ "$RC" -ne 2 ] && [[ "$OUT" != *"manifest="* ]] \
    && ok "control: without the manifest refusal the unreadable list is not refused" \
    || bad "control: without the manifest refusal the unreadable list is not refused" "rc=$RC out=$OUT"
else
  bad "control: the manifest refusal was not changed in the script copy"
fi

echo "=== controls ==="
reset_world
plant skills/alpha/scripts/rule.sh '#!/usr/bin/env bash\n# REVISIT(D015): a usage field\necho rule'
plant skills/alpha/README.md 'Per D016 the route holds.'
if mutant 'printf "decision\t' 's/printf "decision\\t/if (0) &/'; then
  run "$MUTANT"
  [ "$RC" -eq 0 ] && ok "control: without the decision finding both citations pass" \
    || bad "control: without the decision finding both citations pass" "rc=$RC out=$OUT"
else
  bad "control: the decision finding was not changed in the script copy"
fi
reset_world
plant skills/alpha/README.md '[optional](../gamma/SKILL.md)'
if mutant 'printf "link\t' 's/printf "link\\t/if (0) &/'; then
  run "$MUTANT"
  [ "$RC" -eq 0 ] && ok "control: without the link finding the optional link passes" \
    || bad "control: without the link finding the optional link passes" "rc=$RC out=$OUT"
else
  bad "control: the link finding was not changed in the script copy"
fi
reset_world
plant skills/alpha/README.md '## [optional](../gamma/SKILL.md)'
if mutant 'if (block_kind != "X") emit_links' 's/if (block_kind != "X") emit_links/if (block_kind != "H" \&\& block_kind != "X") emit_links/'; then
  run "$MUTANT"
  [ "$RC" -eq 0 ] && ok "control: with headings unread for links the heading link passes" \
    || bad "control: with headings unread for links the heading link passes" "rc=$RC out=$OUT"
else
  bad "control: the heading link reading was not changed in the script copy"
fi
reset_world
plant skills/alpha/README.md 'The [optional](../gamma/SKILL.md) one\n==='
if mutant '&& setext_underline(line_no)) next' 's/if (block_kind == "H" \&\& setext_underline(line_no)) next//'; then
  run "$MUTANT"
  [ "$RC" -eq 1 ] && [[ "$OUT" == *"shipped-refs: links=2"* ]] \
    && ok "control: reading a setext heading's record cites its link twice" \
    || bad "control: reading a setext heading's record cites its link twice" "rc=$RC out=$OUT"
else
  bad "control: the setext heading skip was not changed in the script copy"
fi
reset_world
plant pi-extensions/pi-demo/node_modules/dep/README.md 'D016'
if mutant 'PI_SKIPPED="' 's/^PI_SKIPPED=.*/PI_SKIPPED=""/'; then
  run "$MUTANT"
  [ "$RC" -eq 1 ] && [[ "$OUT" == "shipped-refs: decisions="* ]] \
    && ok "control: with no Pi copy exclusion a node_modules file is judged" \
    || bad "control: with no Pi copy exclusion a node_modules file is judged" "rc=$RC out=$OUT"
else
  bad "control: the Pi copy exclusion was not changed in the script copy"
fi

printf '\n=== %s passed, %s failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
