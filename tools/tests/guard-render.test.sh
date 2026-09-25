#!/usr/bin/env bash
# tools/guard's render rule: a render source lands its tracked renders in the
# same change and the renders outlive it. Rendered is judged at the tree for
# skills and agents and per file for hooks. Each control below removes one
# clause from a guard copy and expects the same defect to pass.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/guard-world.sh
. "$TEST_DIR/lib/guard-world.sh"

echo "=== a skill source lands its render in the same change ==="
printf 'echo more\n' >>"$R/skills/demo/scripts/demo.sh"
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
run_guard
[ "$RC" -eq 0 ] \
  && ok "the same edit with its render in the change passes" \
  || bad "the same edit with its render in the change passes" "rc=$RC out=$OUT"
git -C "$R" checkout -q -- skills .agents

# A deletion is in the changed set too, so a render removed beside a living
# source has to red; both gone together is a clean removal.
printf 'echo more\n' >>"$R/skills/demo/scripts/demo.sh"
rm -f "$R/.agents/skills/demo/scripts/demo.sh"
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"skills/demo/scripts/demo.sh -> .agents/skills/demo/scripts/demo.sh"* ]] \
  && ok "a skill source edited with its render deleted reds, naming the render" \
  || bad "a skill source edited with its render deleted reds, naming the render" "rc=$RC out=$OUT"
if mutant_guard 's/ && { \[ ! -e "\$1" \] || \[ -e "\$2" \]; }//'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the outlives clause deleted the deleted render passes" \
    || bad "control: with the outlives clause deleted the deleted render passes" "rc=$RC out=$OUT"
else
  bad "control: the outlives clause could not be deleted from a guard copy"
fi
rm -f "$R/skills/demo/scripts/demo.sh"
run_guard
[ "$RC" -eq 0 ] \
  && ok "a skill source deleted with its render passes" \
  || bad "a skill source deleted with its render passes" "rc=$RC out=$OUT"
git -C "$R" checkout -q -- skills .agents

# A path with a non-ASCII byte: git quotes it unless told not to, and the
# quoted spelling would slip past the case arm.
printf 'echo more\n' >>"$R/skills/demo/scripts/frappé.sh"
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
git -C "$R" checkout -q -- skills .agents

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
git -C "$R" checkout -q -- skills .agents
git -C "$R" reset -q --hard HEAD~1

echo "=== an agent definition lands a render in every harness directory that tracks any ==="
AGENT_RENDERS=(.claude/agents/demo.md .codex/agents/demo.toml .pi/agents/demo.md)
for r in "${AGENT_RENDERS[@]}"; do
  git -C "$R" checkout -q -- agents .claude/agents .codex .pi
  printf '# amended\n' >>"$R/agents/demo.md"
  for other in "${AGENT_RENDERS[@]}"; do
    [ "$other" = "$r" ] || printf '# amended\n' >>"$R/$other"
  done
  run_guard
  [ "$RC" -ne 0 ] && [[ "$OUT" == *"agents/demo.md -> $r"* ]] \
    && ok "an agent edit leaving $r behind reds, naming it" \
    || bad "an agent edit leaving $r behind reds, naming it" "rc=$RC out=$OUT"
done
git -C "$R" checkout -q -- agents .claude/agents .codex .pi
printf '# amended\n' >>"$R/agents/demo.md"
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
run_guard
[ "$RC" -eq 0 ] \
  && ok "an agent edit landing all three renders passes" \
  || bad "an agent edit landing all three renders passes" "rc=$RC out=$OUT"
git -C "$R" checkout -q -- agents .claude/agents .codex .pi

printf '# amended\n' >>"$R/agents/demo.md"
printf '# amended\n' >>"$R/.codex/agents/demo.toml"
printf '# amended\n' >>"$R/.pi/agents/demo.md"
rm -f "$R/.claude/agents/demo.md"
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"agents/demo.md -> .claude/agents/demo.md"* ]] \
  && [[ "$OUT" != *"-> .codex/agents/demo.toml"* ]] && [[ "$OUT" != *"-> .pi/agents/demo.md"* ]] \
  && ok "an agent edit with one harness render deleted reds, naming that render alone" \
  || bad "an agent edit with one harness render deleted reds, naming that render alone" "rc=$RC out=$OUT"
git -C "$R" checkout -q -- agents .claude/agents .codex .pi

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
# Pi renders no model for opus or inherit, so moving between them leaves the
# Pi render byte-identical and owes it nothing. Every other change owes the
# render: a value Pi does render, on either side, a model line removed or
# added outright (an absent model is sonnet), and a model: line in the body.
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

seed_pinned opus opus
land_pinned inherit opus
run_guard
[ "$RC" -eq 0 ] \
  && ok "an opus -> inherit frontmatter edit leaving the Pi render unchanged passes" \
  || bad "an opus -> inherit frontmatter edit leaving the Pi render unchanged passes" "rc=$RC out=$OUT"
if mutant_guard '/^    render_unchanged_by "\$1" "\$2" ||$/d'; then
  run_mutant
  [ "$RC" -ne 0 ] && [[ "$OUT" == *"agents/pinned.md -> .pi/agents/pinned.md"* ]] \
    && ok "control: with the allowance deleted the unchanged Pi render reds" \
    || bad "control: with the allowance deleted the unchanged Pi render reds" "rc=$RC out=$OUT"
else
  bad "control: the unchanged-render allowance could not be deleted from a guard copy"
fi
git -C "$R" reset -q --hard HEAD

# The commit records the index: a staged sonnet owes the Pi render though the
# worktree beside it has moved on to inherit.
land_pinned sonnet opus
write_pinned inherit opus
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"agents/pinned.md -> .pi/agents/pinned.md"* ]] \
  && ok "a staged opus -> sonnet edit with inherit unstaged beside it reds, naming the Pi render" \
  || bad "a staged opus -> sonnet edit with inherit unstaged beside it reds, naming the Pi render" "rc=$RC out=$OUT"
if mutant_guard 's/^  if \[ "\$MODE" = default \]; then$/  if false; then/'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the worktree read in place of the index the staged sonnet passes" \
    || bad "control: with the worktree read in place of the index the staged sonnet passes" "rc=$RC out=$OUT"
else
  bad "control: the index read could not be removed from a guard copy"
fi
git -C "$R" reset -q --hard HEAD

# The allowance is per render root: the Claude render does carry the model.
write_pinned inherit opus
printf '# amended\n' >>"$R/.codex/agents/pinned.toml"
git -C "$R" add agents/pinned.md .codex/agents/pinned.toml
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"agents/pinned.md -> .claude/agents/pinned.md"* ]] \
  && [[ "$OUT" != *"-> .pi/agents/pinned.md"* ]] \
  && ok "the same edit leaving the Claude render unchanged reds, naming Claude and not Pi" \
  || bad "the same edit leaving the Claude render unchanged reds, naming Claude and not Pi" "rc=$RC out=$OUT"
if mutant_guard 's/return (root " " key " " value) in listed/return (".pi\/agents " key " " value) in listed/'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with every root read as .pi/agents the unchanged Claude render passes" \
    || bad "control: with every root read as .pi/agents the unchanged Claude render passes" "rc=$RC out=$OUT"
else
  bad "control: the root scope could not be removed from a guard copy"
fi
git -C "$R" reset -q --hard HEAD~1

# ROW: seeded model | seeded body model | edited model | edited body model | guard edit that removes the row's rule
PINNED_ROWS=(
  "opus|opus|sonnet|opus|s/^\.pi\/agents model parent'\$/.pi\/agents model parent\n.pi\/agents model sonnet'/"
  "sonnet|opus|inherit|opus|s/^    \/^-\/ { if (!blind(substr(\$0, 2), o++, old_end)) { bad = 1; exit } /    \/^-\/ { blind(substr(\$0, 2), o++, old_end); /"
  "opus|opus||opus|s/ if (!bad) for (k in moved) if (moved\[k\]) bad = 1;//"
  "|opus|inherit|opus|s/ if (!bad) for (k in moved) if (moved\[k\]) bad = 1;//"
  "opus|opus|opus|inherit|s/ || line >= end + 0 / /"
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

echo "=== a hook lands the renders it already has ==="
# Hooks are judged per file: the two harness copies this hook already has
# are owed, the third harness directory is not, and a hook test that renders
# nowhere owes nothing.
printf 'echo more\n' >>"$R/hooks/demo.sh"
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
run_guard
[ "$RC" -eq 0 ] \
  && ok "a hook edit landing both tracked renders passes" \
  || bad "a hook edit landing both tracked renders passes" "rc=$RC out=$OUT"
git -C "$R" checkout -q -- hooks .claude/hooks .codex/hooks

# Staging a render's deletion takes it out of the index, and the index alone
# would then read the hook as unrendered and owe nothing. Both renders go, so
# no surviving copy can red this for another reason: the union with HEAD is
# what keeps the rule running, and the outlives clause is what refuses.
printf 'echo more\n' >>"$R/hooks/demo.sh"
git -C "$R" rm -q .claude/hooks/demo.sh .codex/hooks/demo.sh
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"hooks/demo.sh -> .claude/hooks/demo.sh"* ]] \
  && [[ "$OUT" == *"hooks/demo.sh -> .codex/hooks/demo.sh"* ]] \
  && ok "a hook edit staging its renders' deletion reds, naming both" \
  || bad "a hook edit staging its renders' deletion reds, naming both" "rc=$RC out=$OUT"
git -C "$R" reset -q HEAD -- .claude/hooks .codex/hooks
git -C "$R" checkout -q -- hooks .claude/hooks .codex/hooks

printf 'echo more\n' >>"$R/hooks/tests/demo.test.sh"
run_guard
[ "$RC" -eq 0 ] \
  && ok "a hook test with no render anywhere passes" \
  || bad "a hook test with no render anywhere passes" "rc=$RC out=$OUT"
git -C "$R" checkout -q -- hooks

# A harness directory that tracks nothing is owed nothing.
git -C "$R" rm -q .pi/agents/demo.md
git -C "$R" commit -q -m "chore: no pi renders"
printf '# amended\n' >>"$R/agents/demo.md"
printf '# amended\n' >>"$R/.claude/agents/demo.md"
printf '# amended\n' >>"$R/.codex/agents/demo.toml"
run_guard
[ "$RC" -eq 0 ] \
  && ok "an agent edit with no pi render tracked anywhere passes without one" \
  || bad "an agent edit with no pi render tracked anywhere passes without one" "rc=$RC out=$OUT"
git -C "$R" reset -q --hard HEAD~1

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
