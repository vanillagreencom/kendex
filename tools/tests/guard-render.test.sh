#!/usr/bin/env bash
# tools/guard's render rule: a render source lands its tracked renders in the
# same change and the renders outlive it. Rendered is judged at the tree for
# skills and agents and per file for hooks. Each control below removes one
# clause from a guard copy and expects the same defect to pass. At commit
# time the rule judges the index, so a row stages what it plants unless the
# row is about what the worktree holds beside the index.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/guard-world.sh
. "$TEST_DIR/lib/guard-world.sh"

echo "=== a skill source lands its render in the same change ==="
printf 'echo more\n' >>"$R/skills/demo/scripts/demo.sh"
git -C "$R" add -A
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: missing-render=1"* ]] \
  && [[ "$OUT" == *"skills/demo/scripts/demo.sh -> .agents/skills/demo/scripts/demo.sh"* ]] \
  && ok "a source-only skill edit reds, naming the render left behind" \
  || bad "a source-only skill edit reds, naming the render left behind" "rc=$RC out=$OUT"
if mutant_guard '/\.agents\/\$f/d'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the skills arm deleted the source-only edit passes" \
    || bad "control: with the skills arm deleted the source-only edit passes" "rc=$RC out=$OUT"
else
  bad "control: the skills render arm could not be deleted from a guard copy"
fi
printf 'echo more\n' >>"$R/.agents/skills/demo/scripts/demo.sh"
git -C "$R" add -A
run_guard
[ "$RC" -eq 0 ] \
  && ok "the same edit with its render in the change passes" \
  || bad "the same edit with its render in the change passes" "rc=$RC out=$OUT"
git -C "$R" reset -q --hard HEAD

# A deletion is in the changed set too, so a render removed beside a living
# source has to red; both gone together is a clean removal.
printf 'echo more\n' >>"$R/skills/demo/scripts/demo.sh"
rm -f "$R/.agents/skills/demo/scripts/demo.sh"
git -C "$R" add -A
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"skills/demo/scripts/demo.sh -> .agents/skills/demo/scripts/demo.sh"* ]] \
  && ok "a skill source edited with its render deleted reds, naming the render" \
  || bad "a skill source edited with its render deleted reds, naming the render" "rc=$RC out=$OUT"
if mutant_guard 's/ \&\& { ! render_has "\$1" || render_has "\$2"; }//'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the outlives clause deleted the deleted render passes" \
    || bad "control: with the outlives clause deleted the deleted render passes" "rc=$RC out=$OUT"
else
  bad "control: the outlives clause could not be deleted from a guard copy"
fi
rm -f "$R/skills/demo/scripts/demo.sh"
git -C "$R" add -A
run_guard
[ "$RC" -eq 0 ] \
  && ok "a skill source deleted with its render passes" \
  || bad "a skill source deleted with its render passes" "rc=$RC out=$OUT"
git -C "$R" reset -q --hard HEAD

# Outlives is judged in the index: a render staged for deletion is gone from
# the commit though the worktree still holds it.
printf 'echo more\n' >>"$R/skills/demo/scripts/demo.sh"
git -C "$R" add skills/demo/scripts/demo.sh
git -C "$R" rm -q --cached .agents/skills/demo/scripts/demo.sh
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"skills/demo/scripts/demo.sh -> .agents/skills/demo/scripts/demo.sh"* ]] \
  && ok "a skill source edited with its render's deletion staged and the file kept reds, naming the render" \
  || bad "a skill source edited with its render's deletion staged and the file kept reds, naming the render" "rc=$RC out=$OUT"
if mutant_guard 's/{ ! render_has "\$1" || render_has "\$2"; }/{ [ ! -e "$1" ] || [ -e "$2" ]; }/'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with existence read from the worktree the kept render passes" \
    || bad "control: with existence read from the worktree the kept render passes" "rc=$RC out=$OUT"
else
  bad "control: the outlives clause could not be pointed at the worktree in a guard copy"
fi
git -C "$R" reset -q --hard HEAD

# A path with a non-ASCII byte: git quotes it unless told not to, and the
# quoted spelling would slip past the case arm.
printf 'echo more\n' >>"$R/skills/demo/scripts/frappé.sh"
git -C "$R" add -A
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"skills/demo/scripts/frappé.sh -> .agents/skills/demo/scripts/frappé.sh"* ]] \
  && ok "a source-only edit to a non-ASCII path reds, naming the render left behind" \
  || bad "a source-only edit to a non-ASCII path reds, naming the render left behind" "rc=$RC out=$OUT"
if mutant_guard 's/-c core.quotePath=false //g'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with path quoting left on the non-ASCII edit passes" \
    || bad "control: with path quoting left on the non-ASCII edit passes" "rc=$RC out=$OUT"
else
  bad "control: path quoting could not be turned back on in a guard copy"
fi
git -C "$R" reset -q --hard HEAD

# Rendered is judged at the tree, so each file in a rendered skill owes a
# render the tree does not track yet.
printf '#!/usr/bin/env bash\necho added\n' >"$R/skills/demo/scripts/added.sh"
git -C "$R" add skills/demo/scripts/added.sh
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"skills/demo/scripts/added.sh -> .agents/skills/demo/scripts/added.sh"* ]] \
  && ok "a new script in a rendered skill with no render reds, naming it" \
  || bad "a new script in a rendered skill with no render reds, naming it" "rc=$RC out=$OUT"
if mutant_guard '/\.agents\/\$f/d'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the skills arm deleted the new script passes" \
    || bad "control: with the skills arm deleted the new script passes" "rc=$RC out=$OUT"
else
  bad "control: the skills render arm could not be deleted from a guard copy"
fi
cp "$R/skills/demo/scripts/added.sh" "$R/.agents/skills/demo/scripts/added.sh"
git -C "$R" add .agents/skills/demo/scripts/added.sh
run_guard
[ "$RC" -eq 0 ] \
  && ok "the new script with its render staged beside it passes" \
  || bad "the new script with its render staged beside it passes" "rc=$RC out=$OUT"
git -C "$R" reset -q HEAD -- skills .agents
rm -f "$R/skills/demo/scripts/added.sh" "$R/.agents/skills/demo/scripts/added.sh"

# A render leaves out a skill's top-level tests/, evals/ and DEVELOPMENT.md,
# so an edit there owes none; the same name deeper in the tree is content
# and does. One row per path, one control for the one rule.
# path | owes a render (1) or not (0)
not_rendered_rows=0
while IFS='|' read -r rel owes; do
  not_rendered_rows=$((not_rendered_rows + 1))
  mkdir -p "$R/skills/demo/$(dirname "$rel")"
  printf 'echo more\n' >>"$R/skills/demo/$rel"
  git -C "$R" add -A
  run_guard
  if [ "$owes" = 1 ]; then
    [ "$RC" -ne 0 ] && [[ "$OUT" == *"skills/demo/$rel -> .agents/skills/demo/$rel"* ]] \
      && ok "a source-only edit to $rel reds, naming its render" \
      || bad "a source-only edit to $rel reds, naming its render" "rc=$RC out=$OUT"
  else
    [ "$RC" -eq 0 ] \
      && ok "a source-only edit to $rel owes no render and passes" \
      || bad "a source-only edit to $rel owes no render and passes" "rc=$RC out=$OUT"
  fi
  git -C "$R" reset -q --hard HEAD
  git -C "$R" clean -qfd -- skills
done <<'ROWS'
tests/demo.test.sh|0
evals/cases.json|0
DEVELOPMENT.md|0
templates/DEVELOPMENT.md|1
scripts/tests/case.sh|1
ROWS
[ "$not_rendered_rows" -eq 5 ] || bad "the not-rendered table ran $not_rendered_rows rows, not 5"
printf 'echo more\n' >>"$R/skills/demo/tests/demo.test.sh"
git -C "$R" add -A
if mutant_guard '/^    rendered_in_skill "\${x#\*\/}" || continue$/d'; then
  run_mutant
  [ "$RC" -ne 0 ] && [[ "$OUT" == *"skills/demo/tests/demo.test.sh -> .agents/skills/demo/tests/demo.test.sh"* ]] \
    && ok "control: with the not-rendered exemption deleted a skill test edit reds" \
    || bad "control: with the not-rendered exemption deleted a skill test edit reds" "rc=$RC out=$OUT"
else
  bad "control: the not-rendered exemption could not be deleted from a guard copy"
fi
git -C "$R" reset -q --hard HEAD

mkdir -p "$R/skills/other/scripts"
printf '#!/usr/bin/env bash\necho local\n' >"$R/skills/other/scripts/local-only.sh"
git -C "$R" add skills/other/scripts/local-only.sh
run_guard
[ "$RC" -eq 0 ] \
  && ok "a source in a skill with no tracked render passes" \
  || bad "a source in a skill with no tracked render passes" "rc=$RC out=$OUT"
git -C "$R" reset -q HEAD -- skills/other
rm -rf "$R/skills/other"

# A rendered skill whose name carries a regex metacharacter: the prefix test
# reads the name literally, or a bracket makes the match fail as not rendered.
mkdir -p "$R/skills/demo[1/scripts" "$R/.agents/skills/demo[1/scripts"
printf '#!/usr/bin/env bash\necho bracket\n' >"$R/skills/demo[1/scripts/b.sh"
cp "$R/skills/demo[1/scripts/b.sh" "$R/.agents/skills/demo[1/scripts/b.sh"
git -C "$R" add -A skills .agents
git -C "$R" commit -q -m "chore: a skill with a bracket in its name"
printf 'echo more\n' >>"$R/skills/demo[1/scripts/b.sh"
git -C "$R" add -A
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"skills/demo[1/scripts/b.sh -> .agents/skills/demo[1/scripts/b.sh"* ]] \
  && ok "a source-only edit in a skill named with a bracket reds, naming the render" \
  || bad "a source-only edit in a skill named with a bracket reds, naming the render" "rc=$RC out=$OUT"
if mutant_guard 's|^  case "\$NL\$render_tracked\$NL" in \*"\$NL\$1/"\*) return 0 ;; esac$|  grep -q -- "^$1/" <<<"$render_tracked" \&\& return 0|'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the name read as a pattern the bracket edit passes" \
    || bad "control: with the name read as a pattern the bracket edit passes" "rc=$RC out=$OUT"
else
  bad "control: the literal prefix test could not be turned back into a pattern in a guard copy"
fi
git -C "$R" reset -q --hard HEAD~1

echo "=== an agent definition lands a render in every harness directory that tracks any ==="
AGENT_RENDERS=(.claude/agents/scout.md .codex/agents/scout.toml .pi/agents/scout.md)
for r in "${AGENT_RENDERS[@]}"; do
  git -C "$R" reset -q --hard HEAD
  printf '# amended\n' >>"$R/agents/scout.md"
  for other in "${AGENT_RENDERS[@]}"; do
    [ "$other" = "$r" ] || printf '# amended\n' >>"$R/$other"
  done
  git -C "$R" add -A
  run_guard
  [ "$RC" -ne 0 ] && [[ "$OUT" == *"agents/scout.md -> $r"* ]] \
    && ok "an agent edit leaving $r behind reds, naming it" \
    || bad "an agent edit leaving $r behind reds, naming it" "rc=$RC out=$OUT"
done
git -C "$R" reset -q --hard HEAD
printf '# amended\n' >>"$R/agents/scout.md"
git -C "$R" add -A
if mutant_guard '/^  agents\/\*\.md)$/,/^    ;;$/d'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the agent render lines deleted the lone agent edit passes" \
    || bad "control: with the agent render lines deleted the lone agent edit passes" "rc=$RC out=$OUT"
else
  bad "control: the agent render lines could not be deleted from a guard copy"
fi
for other in "${AGENT_RENDERS[@]}"; do
  printf '# amended\n' >>"$R/$other"
done
git -C "$R" add -A
run_guard
[ "$RC" -eq 0 ] \
  && ok "an agent edit landing all three renders passes" \
  || bad "an agent edit landing all three renders passes" "rc=$RC out=$OUT"
git -C "$R" reset -q --hard HEAD

printf '# amended\n' >>"$R/agents/scout.md"
printf '# amended\n' >>"$R/.codex/agents/scout.toml"
printf '# amended\n' >>"$R/.pi/agents/scout.md"
rm -f "$R/.claude/agents/scout.md"
git -C "$R" add -A
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"agents/scout.md -> .claude/agents/scout.md"* ]] \
  && [[ "$OUT" != *"-> .codex/agents/scout.toml"* ]] && [[ "$OUT" != *"-> .pi/agents/scout.md"* ]] \
  && ok "an agent edit with one harness render deleted reds, naming that render alone" \
  || bad "an agent edit with one harness render deleted reds, naming that render alone" "rc=$RC out=$OUT"
git -C "$R" reset -q --hard HEAD

# An agent definition owes a render to every harness directory that
# tracks any, though none of its own is tracked yet. The control puts the
# per-file judgement back — a render owed only when it is already tracked.
printf '# fresh agent\n' >"$R/agents/fresh.md"
git -C "$R" add agents/fresh.md
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"agents/fresh.md -> .claude/agents/fresh.md"* ]] \
  && [[ "$OUT" == *"agents/fresh.md -> .codex/agents/fresh.toml"* ]] \
  && [[ "$OUT" == *"agents/fresh.md -> .pi/agents/fresh.md"* ]] \
  && ok "a new agent definition with no render reds, naming all three" \
  || bad "a new agent definition with no render reds, naming all three" "rc=$RC out=$OUT"
if mutant_guard 's|^require_render() { |require_render() { git ls-files --error-unmatch -- "$2" >/dev/null 2>\&1 \|\| return 0; |'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with rendered judged per file the new agent passes" \
    || bad "control: with rendered judged per file the new agent passes" "rc=$RC out=$OUT"
else
  bad "control: the per-file judgement could not be put back in a guard copy"
fi
printf '# fresh agent render\n' >"$R/.claude/agents/fresh.md"
printf 'name = "fresh"\n' >"$R/.codex/agents/fresh.toml"
printf '# fresh agent render\n' >"$R/.pi/agents/fresh.md"
git -C "$R" add .claude/agents/fresh.md .codex/agents/fresh.toml .pi/agents/fresh.md
run_guard
[ "$RC" -eq 0 ] \
  && ok "the new agent with its three renders staged beside it passes" \
  || bad "the new agent with its three renders staged beside it passes" "rc=$RC out=$OUT"
git -C "$R" reset -q HEAD -- agents .claude/agents .codex .pi
rm -f "$R/agents/fresh.md" "$R/.claude/agents/fresh.md" "$R/.codex/agents/fresh.toml" "$R/.pi/agents/fresh.md"

echo "=== a render the source change leaves unchanged ==="
# A root renders current and inherit alike, so moving between them leaves
# its render byte-identical and owes it nothing. Every other change owes the
# render: two values the root renders differently, a value no row lists, a
# model line removed or added outright (an absent model is sonnet), and a
# model: line in the body.
write_pinned() { # FRONTMATTER-MODEL BODY-MODEL — an empty frontmatter model writes no line
  {
    printf -- '---\nname: pinned\n'
    [ -z "$1" ] || printf 'model: %s\n' "$1"
    printf -- '---\n# pinned agent\nmodel: %s\n' "$2"
  } >"$R/agents/pinned.md"
}
seed_pinned() { # FRONTMATTER-MODEL BODY-MODEL — commit that source with every render
  write_pinned "$1" "$2"
  for r in .claude/agents/pinned.md .codex/agents/pinned.toml .pi/agents/pinned.md; do
    printf '# pinned render %s\n' "$1" >"$R/$r"
  done
  git -C "$R" add -A agents .claude/agents .codex/agents .pi/agents
  git -C "$R" commit -q -m "chore: an agent with a model in its frontmatter"
}
land_pinned() { # FRONTMATTER-MODEL BODY-MODEL — stage that source and the Claude and Codex renders, leave Pi
  write_pinned "$1" "$2"
  printf '# amended\n' >>"$R/.claude/agents/pinned.md"
  printf '# amended\n' >>"$R/.codex/agents/pinned.toml"
  git -C "$R" add agents/pinned.md .claude/agents/pinned.md .codex/agents/pinned.toml
}

seed_pinned current current
land_pinned inherit current
run_guard
[ "$RC" -eq 0 ] \
  && ok "an current -> inherit frontmatter edit leaving the Pi render unchanged passes" \
  || bad "an current -> inherit frontmatter edit leaving the Pi render unchanged passes" "rc=$RC out=$OUT"
if mutant_guard '/^    render_unchanged_by "\$1" "\$2" ||$/d'; then
  run_mutant
  [ "$RC" -ne 0 ] && [[ "$OUT" == *"agents/pinned.md -> .pi/agents/pinned.md"* ]] \
    && ok "control: with the allowance deleted the unchanged Pi render reds" \
    || bad "control: with the allowance deleted the unchanged Pi render reds" "rc=$RC out=$OUT"
else
  bad "control: the unchanged-render allowance could not be deleted from a guard copy"
fi
git -C "$R" reset -q --hard HEAD

# macOS runs BSD awk, which refuses a newline in a -v value; the shim below
# refuses the same way, so a Linux run judges the allowance as macOS does.
mkdir -p "$TMP/bsd-awk"
cat >"$TMP/bsd-awk/awk" <<'SH'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  if [ "$prev" = -v ] && [[ "$a" == *$'\n'* ]]; then
    echo "awk: newline in string ${a%%$'\n'*}... at source line 1" >&2
    exit 2
  fi
  prev=$a
done
exec "$REAL_AWK" "$@"
SH
chmod +x "$TMP/bsd-awk/awk"
land_pinned inherit current
run_guard PATH="$TMP/bsd-awk:$PATH" REAL_AWK="$REAL_AWK"
[ "$RC" -eq 0 ] \
  && ok "under an awk refusing a newline in a -v value the current -> inherit edit passes" \
  || bad "under an awk refusing a newline in a -v value the current -> inherit edit passes" "rc=$RC out=$OUT"
if mutant_guard 's/^  RENDER_BLIND="\$render_blind" awk -v root="\${2%\/\*}" -v old_end="\$old_end" -v new_end="\$new_end" '"'"'$/  awk -v root="${2%\/*}" -v old_end="$old_end" -v new_end="$new_end" -v rows="$render_blind" '"'"'/; s/split(ENVIRON\["RENDER_BLIND"\], r,/split(rows, r,/'; then
  PATH="$TMP/bsd-awk:$PATH" REAL_AWK="$REAL_AWK" run_mutant
  [ "$RC" -ne 0 ] && [[ "$OUT" == *"awk: newline in string"* ]] \
    && [[ "$OUT" == *"agents/pinned.md -> .pi/agents/pinned.md"* ]] \
    && ok "control: with the rows passed through -v the same edit reds under that awk" \
    || bad "control: with the rows passed through -v the same edit reds under that awk" "rc=$RC out=$OUT"
else
  bad "control: the rows could not be moved back into a -v value in a guard copy"
fi
git -C "$R" reset -q --hard HEAD

# The commit records the index: a staged sonnet owes the Pi render though the
# worktree beside it has moved on to inherit.
land_pinned sonnet current
write_pinned inherit current
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"agents/pinned.md -> .pi/agents/pinned.md"* ]] \
  && ok "a staged current -> sonnet edit with inherit unstaged beside it reds, naming the Pi render" \
  || bad "a staged current -> sonnet edit with inherit unstaged beside it reds, naming the Pi render" "rc=$RC out=$OUT"
if mutant_guard '/^# The whole rule reads one tree\./,/^fi$/s/^if \[ "\$MODE" = default \]; then$/if false; then/'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the worktree read in place of the index the staged sonnet passes" \
    || bad "control: with the worktree read in place of the index the staged sonnet passes" "rc=$RC out=$OUT"
else
  bad "control: the index read could not be removed from a guard copy"
fi
git -C "$R" reset -q --hard HEAD

# The changed set is the index's too. An unstaged current -> inherit edit is not
# in the commit, so it owes nothing to a commit of another file; a Pi render
# edited only in the worktree does not land beside a staged sonnet.
CHANGED_SET_CONTROL='s/--name-only --no-renames "\${render_diff\[@\]}")/--name-only --no-renames HEAD)/'
write_pinned inherit current
printf '# amended\n' >>"$R/.claude/agents/pinned.md"
printf '# amended\n' >>"$R/.codex/agents/pinned.toml"
printf 'notes\n' >"$R/notes.txt"
git -C "$R" add notes.txt
run_guard
[ "$RC" -eq 0 ] \
  && ok "an unrelated commit beside an unstaged current -> inherit edit passes" \
  || bad "an unrelated commit beside an unstaged current -> inherit edit passes" "rc=$RC out=$OUT"
if mutant_guard "$CHANGED_SET_CONTROL"; then
  run_mutant
  [ "$RC" -ne 0 ] && [[ "$OUT" == *"agents/pinned.md -> .pi/agents/pinned.md"* ]] \
    && ok "control: with the changed set read from the worktree the unrelated commit reds" \
    || bad "control: with the changed set read from the worktree the unrelated commit reds" "rc=$RC out=$OUT"
else
  bad "control: the changed set could not be pointed at the worktree in a guard copy"
fi
git -C "$R" reset -q --hard HEAD
land_pinned sonnet current
printf '# amended\n' >>"$R/.pi/agents/pinned.md"
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"agents/pinned.md -> .pi/agents/pinned.md"* ]] \
  && ok "a staged current -> sonnet edit with the Pi render edited only in the worktree reds, naming it" \
  || bad "a staged current -> sonnet edit with the Pi render edited only in the worktree reds, naming it" "rc=$RC out=$OUT"
if mutant_guard "$CHANGED_SET_CONTROL"; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the changed set read from the worktree the unstaged Pi render passes" \
    || bad "control: with the changed set read from the worktree the unstaged Pi render passes" "rc=$RC out=$OUT"
else
  bad "control: the changed set could not be pointed at the worktree in a guard copy"
fi
git -C "$R" reset -q --hard HEAD

# The allowance is per render root: Claude and Pi render light as a model,
# Codex renders it as none.
write_pinned light current
git -C "$R" add agents/pinned.md
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"agents/pinned.md -> .claude/agents/pinned.md"* ]] \
  && [[ "$OUT" == *"agents/pinned.md -> .pi/agents/pinned.md"* ]] \
  && [[ "$OUT" != *"-> .codex/agents/pinned.toml"* ]] \
  && ok "a current -> light edit leaving every render unchanged reds, naming Claude and Pi and not Codex" \
  || bad "a current -> light edit leaving every render unchanged reds, naming Claude and Pi and not Codex" "rc=$RC out=$OUT"
if mutant_guard 's/row = root " " key " " value/row = ".codex\/agents " key " " value/'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with every root read as .codex/agents the unchanged Claude and Pi renders pass" \
    || bad "control: with every root read as .codex/agents the unchanged Claude and Pi renders pass" "rc=$RC out=$OUT"
else
  bad "control: the root scope could not be removed from a guard copy"
fi
git -C "$R" reset -q --hard HEAD~1

# ROW: seeded model | seeded body model | edited model | edited body model | guard edit that removes the row's rule
PINNED_ROWS=(
  "current|current|sonnet|current|s/ || ((key in rendered) && rendered\[key\] != renders\[row\])//"
  "current|current|opus|current|s/ || ((key in rendered) && rendered\[key\] != renders\[row\])//"
  "gpt-6.1-luna|current|inherit|current|s/^    \/^-\/ { if (!blind(substr(\$0, 2), o++, old_end)) { bad = 1; exit } /    \/^-\/ { blind(substr(\$0, 2), o++, old_end); /"
  "current|current||current|s/ if (!bad) for (k in moved) if (moved\[k\]) bad = 1;//"
  "|current|inherit|current|s/ if (!bad) for (k in moved) if (moved\[k\]) bad = 1;//"
  "current|current|current|inherit|s/ || line >= end + 0 / /"
)
for row in "${PINNED_ROWS[@]}"; do
  IFS='|' read -r seed_model seed_body model body control <<<"$row"
  edit="model '$seed_model' -> '$model', body model '$seed_body' -> '$body'"
  seed_pinned "$seed_model" "$seed_body"
  land_pinned "$model" "$body"
  run_guard
  [ "$RC" -ne 0 ] && [[ "$OUT" == *"agents/pinned.md -> .pi/agents/pinned.md"* ]] \
    && ok "$edit with the Pi render unchanged reds, naming it" \
    || bad "$edit with the Pi render unchanged reds, naming it" "rc=$RC out=$OUT"
  if mutant_guard "$control"; then
    run_mutant
    [ "$RC" -eq 0 ] \
      && ok "control: $edit passes with its rule removed" \
      || bad "control: $edit passes with its rule removed" "rc=$RC out=$OUT"
  else
    bad "control: the rule behind $edit could not be removed from a guard copy"
  fi
  git -C "$R" reset -q --hard HEAD~1
done

# Renders written as the renderer writes each root's model line, every one
# staged: a render the edit leaves byte-identical is not in the change. The
# control renders each value alone, so the same edits red, naming those renders.
render_pinned() { # CLAUDE CODEX PI — each root's rendered model, - for no line
  printf -- '---\nname: pinned\nmodel: %s\n---\n' "$1" >"$R/.claude/agents/pinned.md"
  { printf 'name = "pinned"\n'; [ "$2" = - ] || printf 'model = "%s"\n' "$2"; } >"$R/.codex/agents/pinned.toml"
  { printf -- '---\nname: pinned\n'; [ "$3" = - ] || printf 'model: %s\n' "$3"; printf -- '---\n'; } >"$R/.pi/agents/pinned.md"
}
# ROW: seeded model | its Claude, Codex, Pi renders | edited model | its Claude, Codex, Pi renders | renders left byte-identical
IDENTICAL_ROWS=(
  "inherit|inherit|-|-|standard|opus|-|standard|.codex/agents/pinned.toml"
  "standard|opus|-|standard|light|sonnet|-|light|.codex/agents/pinned.toml"
  "opus|opus|-|standard|standard|opus|-|standard|.claude/agents/pinned.md .codex/agents/pinned.toml .pi/agents/pinned.md"
)
for row in "${IDENTICAL_ROWS[@]}"; do
  IFS='|' read -r seed_model c0 x0 p0 model c1 x1 p1 identical <<<"$row"
  edit="model $seed_model -> $model with $identical byte-identical"
  write_pinned "$seed_model" current
  render_pinned "$c0" "$x0" "$p0"
  git -C "$R" add -A agents .claude/agents .codex/agents .pi/agents
  git -C "$R" commit -q -m "chore: an agent with its rendered models"
  write_pinned "$model" current
  render_pinned "$c1" "$x1" "$p1"
  git -C "$R" add -A agents .claude/agents .codex/agents .pi/agents
  run_guard
  [ "$RC" -eq 0 ] \
    && ok "$edit passes" \
    || bad "$edit passes" "rc=$RC out=$OUT"
  if mutant_guard 's/renders\[f\[1\] " " f\[2\] " " f\[3\]\] = f\[4\]/renders[f[1] " " f[2] " " f[3]] = f[3]/'; then
    run_mutant
    named=1
    for r in $identical; do
      [[ "$OUT" == *"agents/pinned.md -> $r"* ]] || named=0
    done
    [ "$RC" -ne 0 ] && [ "$named" = 1 ] \
      && ok "control: with each value rendered alone $edit reds, naming them" \
      || bad "control: with each value rendered alone $edit reds, naming them" "rc=$RC out=$OUT"
  else
    bad "control: each value could not be rendered alone in a guard copy"
  fi
  git -C "$R" reset -q --hard HEAD~1
done

echo "=== a hook lands the renders it already has ==="
# Hooks are judged per file: the two harness copies this hook already has
# are owed, the third harness directory is not, and a hook test that renders
# nowhere owes nothing.
printf 'echo more\n' >>"$R/hooks/demo.sh"
git -C "$R" add -A
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"hooks/demo.sh -> .claude/hooks/demo.sh"* ]] \
  && [[ "$OUT" == *"hooks/demo.sh -> .codex/hooks/demo.sh"* ]] \
  && [[ "$OUT" != *"-> .pi/kendex/hooks/demo.sh"* ]] \
  && ok "a hook edit reds, naming the two renders it has and not the third" \
  || bad "a hook edit reds, naming the two renders it has and not the third" "rc=$RC out=$OUT"
if mutant_guard '/^  hooks\/\*)$/,/^    ;;$/d'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the hooks arm deleted the source-only hook edit passes" \
    || bad "control: with the hooks arm deleted the source-only hook edit passes" "rc=$RC out=$OUT"
else
  bad "control: the hooks render arm could not be deleted from a guard copy"
fi
printf 'echo more\n' >>"$R/.claude/hooks/demo.sh"
printf 'echo more\n' >>"$R/.codex/hooks/demo.sh"
git -C "$R" add -A
run_guard
[ "$RC" -eq 0 ] \
  && ok "a hook edit landing both tracked renders passes" \
  || bad "a hook edit landing both tracked renders passes" "rc=$RC out=$OUT"
git -C "$R" reset -q --hard HEAD

# Staging a render's deletion takes it out of the index, and the index alone
# would then read the hook as unrendered and owe nothing. Both renders go, so
# no surviving copy can red this for another reason: the union with HEAD is
# what keeps the rule running, and the outlives clause is what refuses.
printf 'echo more\n' >>"$R/hooks/demo.sh"
git -C "$R" add hooks/demo.sh
git -C "$R" rm -q .claude/hooks/demo.sh .codex/hooks/demo.sh
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"hooks/demo.sh -> .claude/hooks/demo.sh"* ]] \
  && [[ "$OUT" == *"hooks/demo.sh -> .codex/hooks/demo.sh"* ]] \
  && ok "a hook edit staging its renders' deletion reds, naming both" \
  || bad "a hook edit staging its renders' deletion reds, naming both" "rc=$RC out=$OUT"
git -C "$R" reset -q --hard HEAD

printf 'echo more\n' >>"$R/hooks/tests/demo.test.sh"
git -C "$R" add -A
run_guard
[ "$RC" -eq 0 ] \
  && ok "a hook test with no render anywhere passes" \
  || bad "a hook test with no render anywhere passes" "rc=$RC out=$OUT"
git -C "$R" reset -q --hard HEAD

# A harness directory that tracks nothing is owed nothing.
git -C "$R" rm -q .pi/agents/scout.md
git -C "$R" commit -q -m "chore: no pi renders"
printf '# amended\n' >>"$R/agents/scout.md"
printf '# amended\n' >>"$R/.claude/agents/scout.md"
printf '# amended\n' >>"$R/.codex/agents/scout.toml"
git -C "$R" add -A
run_guard
[ "$RC" -eq 0 ] \
  && ok "an agent edit with no pi render tracked anywhere passes without one" \
  || bad "an agent edit with no pi render tracked anywhere passes without one" "rc=$RC out=$OUT"
git -C "$R" reset -q --hard HEAD~1

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
