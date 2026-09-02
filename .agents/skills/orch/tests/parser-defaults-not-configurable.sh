#!/usr/bin/env bash
# A value a CLI owns is not configuration.
#
# Its parser's defaults are the largest group of those and the reason this file
# exists; the sweep at the bottom covers every other name the CLIs resolve for
# themselves — where a state file is written, which variable is looked up, and
# which directory a library is sourced from.
#
# lanes, open-terminal and oversee-watch answer help by dry-running their real
# parser before kendex_load_project_env, which means the parser is DEFINED above
# the loader. Its defaults must not be assigned there: the settings [env] table
# assigns any name it likes and .env.local is sourced as shell, so a default
# sitting above the load is whatever the checkout left in that variable for
# every option the caller did not pass. Each parser therefore assigns its own
# defaults as its first statements, and the real call happens after the load.
#
# The signal each case reads is a VALIDATION error the injected value would
# cause. It is deterministic, needs no network, and fails loudly rather than
# quietly changing a run's shape.
#
# Two sources, one fixture each: with both present the .env.local value wins the
# loader's own precedence and lands first, so a settings-file assertion sharing
# the fixture would pass while proving nothing. Arrays are .env.local only — the
# settings contract carries single-line strings, so [env] cannot express one.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_SRC="$(cd "$TEST_DIR/../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n        %s\n' "$1" "$2"
}

# A stub gh so no case reaches the network; every command here fails before or
# at auth, and none of them may decide the outcome by talking to GitHub.
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/no-lanes"
printf '#!/bin/sh\nexit 1\n' >"$TMP_ROOT/bin/gh"
chmod +x "$TMP_ROOT/bin/gh"

# run SCRIPT DIR ARGS... — one hermetic invocation, combined output.
#
# TMUX is unset because oversee-watch's lane-window check only fires outside
# tmux, and this suite must not pass merely because the developer ran it from a
# tmux pane. ORCH_LANE_DIRS points at an empty directory so `lanes` never reads
# the real accounts on this machine.
run() {
  local script="$1" dir="$2"
  shift 2
  # The command's own status is returned, not swallowed: the empty-value sweep
  # below asserts on it. Callers that only read the output append `|| true`.
  (cd "$dir" && PATH="$TMP_ROOT/bin:$PATH" \
    env -u TMUX ORCH_LANES_FETCH_CMD=true ORCH_LANE_DIRS="$TMP_ROOT/no-lanes" \
      "$dir/.agents/skills/orch/scripts/$script" "$@") 2>&1
}

# fixture DIR — a git repository holding the staged skills, so the scripts
# resolve their project root to it from either direction.
#
# github and worktree are staged beside orch because these cases have to REACH
# option validation: open-terminal checks for the worktree CLI first and
# oversee-watch sources the shared GitHub auth helper first, and either missing
# ends the run before the injected value could ever be judged. The controls at
# the bottom are what caught that.
fixture() {
  local dir="$1" skill
  mkdir -p "$dir/.agents/skills"
  for skill in orch github worktree; do
    cp -R "$SKILLS_SRC/$skill" "$dir/.agents/skills/$skill"
    rm -rf -- "${dir:?}/.agents/skills/$skill/tests"
  done
  git -C "$dir" init -q
}

# refute CASE SCRIPT INJECTED_TEXT — the injected value must never reach the
# run. NAME is the case label; the assertion is that the leak's own validation
# message is absent from the output.
refute() { # LABEL DIR SCRIPT LEAK_MARKER ARGS...
  local label="$1" dir="$2" script="$3" marker="$4"
  shift 4
  local out=""
  out="$(run "$script" "$dir" "$@")" || true
  if [ "${out#*"$marker"}" != "$out" ]; then
    bad "$label" "the injected value reached the run: $(printf '%s' "$out" | head -1)"
  else
    ok "$label"
  fi
}

# expect LABEL DIR SCRIPT MARKER ARGS... — the run the CALLER asked for, named
# by a string only a clean parse produces. Used where refuting the injected
# value is not enough: an injected ITEMS entry changes which error comes out,
# not whether the entry is echoed.
expect() {
  local label="$1" dir="$2" script="$3" marker="$4"
  shift 4
  local out=""
  out="$(run "$script" "$dir" "$@")" || true
  if [ "${out#*"$marker"}" != "$out" ]; then
    ok "$label"
  else
    bad "$label" "expected '$marker', got: $(printf '%s' "$out" | head -1)"
  fi
}

echo "=== a parser default is not reachable from project configuration ==="

# CASES — SCRIPT|VAR|VALUE|LEAK_MARKER|ARGS
# VALUE is chosen so that, if it reached the parser's variable, the script's own
# validation would say so in words no clean run produces.
CASES='
lanes|MAX_PCT|zzz|--max-pct must be an integer 0-100|list --harness claude
lanes|HARNESS|bogus|--harness must be claude, codex, or all|list
open-terminal|TRACKER|bogus|--tracker must be linear or github|--harness claude KEN-1
open-terminal|LANE_MAX_PCT|zzz|--max-pct must be an integer 0-100|--lane auto --harness claude --cmd true KEN-1
oversee-watch|INTERVAL|zzz|--interval must be a non-negative integer|--max-loops 1 --repo o/r
oversee-watch|MAX_LOOPS|zzz|--max-loops must be a positive integer|--repo o/r
'

n=0
while IFS='|' read -r script var value marker args; do
  [ -n "$script" ] || continue
  n=$((n + 1))

  dotenv="$TMP_ROOT/dotenv-$n"
  fixture "$dotenv"
  printf '%s=%s\n' "$var" "$value" >"$dotenv/.env.local"
  # shellcheck disable=SC2086 # the table's args are deliberately split
  refute "$script: a .env.local $var never becomes the parser's default" \
    "$dotenv" "$script" "$marker" $args

  settings="$TMP_ROOT/settings-$n"
  fixture "$settings"
  printf '[env]\n%s = "%s"\n' "$var" "$value" >"$settings/kendex.settings.toml"
  # shellcheck disable=SC2086 # the table's args are deliberately split
  refute "$script: a settings [env] $var never becomes the parser's default" \
    "$settings" "$script" "$marker" $args
done <<EOF
$CASES
EOF

# The arrays are the sharpest case: the parse loop APPENDS, so an injected entry
# would ADD to the caller's rather than replace it, and the caller would never
# see that it happened. Only .env.local can carry one.
array_items="$TMP_ROOT/array-items"
fixture "$array_items"
printf 'ITEMS=(KEN-999)\n' >"$array_items/.env.local"
expect "open-terminal: a .env.local ITEMS never joins the caller's work items" \
  "$array_items" open-terminal "no work items specified" --tmux

array_lanes="$TMP_ROOT/array-lanes"
fixture "$array_lanes"
printf 'LANES=(injected-window)\n' >"$array_lanes/.env.local"
refute "oversee-watch: a .env.local LANES never joins the caller's lane windows" \
  "$array_lanes" oversee-watch "injected-window" --max-loops 1 --repo o/r

# The controls for the loop above: each marker must be a string the script really
# does print when the value DOES reach the parser, or every case passes vacuously.
echo
echo "=== the markers are strings these scripts really print ==="
control() { # LABEL SCRIPT MARKER ARGS...
  local label="$1" script="$2" marker="$3"
  shift 3
  local out=""
  out="$(run "$script" "$array_items" "$@")" || true
  if [ "${out#*"$marker"}" != "$out" ]; then
    ok "$label"
  else
    bad "$label" "expected '$marker', got: $(printf '%s' "$out" | head -1)"
  fi
}
control "lanes rejects a bad --max-pct in those words" \
  lanes "--max-pct must be an integer 0-100" list --max-pct zzz
control "lanes rejects a bad --harness in those words" \
  lanes "--harness must be claude, codex, or all" list --harness bogus
control "open-terminal rejects a bad --tracker in those words" \
  open-terminal "--tracker must be linear or github" --tracker bogus --harness claude KEN-1
control "open-terminal rejects a bad --lane-max-pct in those words" \
  open-terminal "--max-pct must be an integer 0-100" --lane-max-pct zzz --lane auto --harness claude --cmd true KEN-1
control "oversee-watch rejects a bad --interval in those words" \
  oversee-watch "--interval must be a non-negative integer" --interval zzz --repo o/r
control "oversee-watch rejects a bad --max-loops in those words" \
  oversee-watch "--max-loops must be a positive integer" --max-loops zzz --repo o/r

# --- a name the CLI owns outright is not configuration either -----------------
#
# These are not parser defaults; they are values a script resolves for itself and
# reads after the loader. Each was reachable from a committed settings file,
# which is PARSED data rather than shell, so no execution was needed to set it.
echo
echo "=== a value a CLI resolves for itself is not settable from configuration ==="

# SCRIPT_DIR is the sharpest: it chooses which directory a library is sourced
# from, so setting it is code execution rather than a changed answer. SKILLS_DIR
# is the same shape one step out — the CLIs EXECUTE what they find under it.
evil="$TMP_ROOT/evil"
mkdir -p "$evil/lib" "$evil/worktree/scripts" "$evil/review-gate/scripts"
for lib in kendex-env lane-claims lane-context gh-auth merge-queue-events; do
  printf 'echo "SOURCED FROM THE CONFIGURED DIRECTORY" >&2\n' >"$evil/lib/$lib.sh"
done
for exe in worktree/scripts/worktree review-gate/scripts/pr-watch.sh; do
  printf '#!/bin/sh\necho "EXECUTED FROM THE CONFIGURED SKILLS_DIR" >&2\nexit 0\n' >"$evil/$exe"
  chmod +x "$evil/$exe"
done

# name_cases NAME MARKER — SCRIPT|ARGS rows for one injected name.
script_dir_cases='
lanes|list
open-terminal|--harness claude KEN-1
oversee-watch|--repo o/r --max-loops 1
'
# open-terminal only. oversee-watch reads SKILLS_DIR the same way, for
# PR_WATCH, but that line is inside the polling loop behind a successful
# `gh pr list`, so in this fixture the row would pass whatever the code did.
# The protection is one shared `export SKILLS_DIR` line, and the leak control
# below is what proves the covered row can fail.
skills_dir_cases='
open-terminal|--harness claude KEN-1
'

# write_config DIR SOURCE_KIND NAME VALUE
write_config() {
  if [ "$2" = dotenv ]; then
    printf '%s=%s\n' "$3" "$4" >"$1/.env.local"
  else
    printf '[env]\n%s = "%s"\n' "$3" "$4" >"$1/kendex.settings.toml"
  fi
}

for source_kind in dotenv settings; do
  for name in SCRIPT_DIR SKILLS_DIR; do
    case "$name" in
    SCRIPT_DIR)
      rows="$script_dir_cases"
      marker="SOURCED FROM THE CONFIGURED DIRECTORY"
      what="chooses which lib is sourced"
      ;;
    SKILLS_DIR)
      rows="$skills_dir_cases"
      marker="EXECUTED FROM THE CONFIGURED SKILLS_DIR"
      what="chooses which helper is executed"
      ;;
    esac
    dir="$TMP_ROOT/own-$name-$source_kind"
    fixture "$dir"
    write_config "$dir" "$source_kind" "$name" "$evil"
    while IFS='|' read -r script args; do
      [ -n "$script" ] || continue
      # shellcheck disable=SC2086 # deliberately split
      refute "$script: a $name in $source_kind never $what" \
        "$dir" "$script" "$marker" $args
    done <<EOF
$rows
EOF
  done
done

# approval-wait is the one CLI holding parse state across its load, and it is
# safe only because that load sits in a branch which prints the resolved gate
# mode and exits without reading a parser variable. These rows pass today and
# red the moment a read of MODE appears below that load.
for source_kind in dotenv settings; do
  dir="$TMP_ROOT/mode-$source_kind"
  fixture "$dir"
  write_config "$dir" "$source_kind" MODE INJECTEDMODE
  refute "approval-wait: a MODE in $source_kind never becomes the resolved mode" \
    "$dir" approval-wait "INJECTEDMODE" --resolve-mode
done

for source_kind in dotenv settings; do
  dir="$TMP_ROOT/prefix-$source_kind"
  fixture "$dir"
  if [ "$source_kind" = dotenv ]; then
    printf 'STATE_PREFIX=hijacked\nVAR_NAME=HIJACKED\nHIJACKED=gotcha\n' >"$dir/.env.local"
  else
    printf '[env]\nSTATE_PREFIX = "hijacked"\nVAR_NAME = "HIJACKED"\nHIJACKED = "gotcha"\n' \
      >"$dir/kendex.settings.toml"
  fi
  # workflow-state names its state file with STATE_PREFIX, and worktree-push
  # finds that file by stripping the same literal, so a renamed one is gate
  # state the rest of the flow cannot see.
  expect "workflow-state: a STATE_PREFIX in $source_kind never renames the state file" \
    "$dir" workflow-state "workflow-state-KEN-1.json" path KEN-1
  # orch-env looks up the NAME it was given, not one the configuration chose.
  expect "orch-env: a VAR_NAME in $source_kind never redirects the lookup" \
    "$dir" orch-env "fallback" SOME_UNSET_KEY fallback
done

# The controls for the refute rows above. A refute passes whenever the marker is
# absent, INCLUDING when the fixture never reached the lines that would print it,
# so each protection is broken in a staged copy here and the row must then leak.
# awk does the editing rather than sed -i, which differs between GNU and BSD.
echo
echo "=== each protection above can actually fail ==="

must_leak() { # LABEL DIR SCRIPT MARKER ARGS...
  local label="$1" dir="$2" script="$3" marker="$4"
  shift 4
  local out=""
  out="$(run "$script" "$dir" "$@")" || true
  if [ "${out#*"$marker"}" != "$out" ]; then
    ok "$label"
  else
    bad "$label" "the row would have passed with the protection gone: $(printf '%s' "$out" | head -1)"
  fi
}

# drop_export DIR SCRIPT NAME — remove the one line that makes NAME survive the
# loader, in the staged copy only.
drop_export() {
  local f="$1/.agents/skills/orch/scripts/$2" name="$3" tmp="$1/edit"
  awk -v n="$name" '$0 == "export " n { next } { print }' "$f" >"$tmp" && mv "$tmp" "$f"
  chmod +x "$f"
  ! grep -qx "export $name" "$f"
}

leak_dir="$TMP_ROOT/leak-script-dir"
fixture "$leak_dir"
write_config "$leak_dir" settings SCRIPT_DIR "$evil"
if drop_export "$leak_dir" lanes SCRIPT_DIR; then
  must_leak "dropping export SCRIPT_DIR lets lanes source from the configured directory" \
    "$leak_dir" lanes "SOURCED FROM THE CONFIGURED DIRECTORY" list
else
  bad "the export SCRIPT_DIR mutation did not land, so it proves nothing"
fi

leak_skills="$TMP_ROOT/leak-skills-dir"
fixture "$leak_skills"
write_config "$leak_skills" settings SKILLS_DIR "$evil"
if drop_export "$leak_skills" open-terminal SKILLS_DIR; then
  must_leak "dropping export SKILLS_DIR lets open-terminal execute from the configured one" \
    "$leak_skills" open-terminal "EXECUTED FROM THE CONFIGURED SKILLS_DIR" --harness claude KEN-1
else
  bad "the export SKILLS_DIR mutation did not land, so it proves nothing"
fi

# approval-wait has no export to drop: what protects it is that the branch
# holding its load exits without reading a parser variable. So the mutation is
# the read itself, which is precisely the case the prose says nothing checks.
leak_mode="$TMP_ROOT/leak-mode"
fixture "$leak_mode"
write_config "$leak_mode" settings MODE INJECTEDMODE
aw="$leak_mode/.agents/skills/orch/scripts/approval-wait"
awk '{ print }
     /^  kendex_load_project_env "\$PROJECT_ROOT"$/ { print "  printf %s\\n \"$MODE\"" }' \
  "$aw" >"$leak_mode/edit" && mv "$leak_mode/edit" "$aw"
chmod +x "$aw"
if grep -q 'printf %s' "$aw"; then
  must_leak "a read of MODE below approval-wait's load prints the injected value" \
    "$leak_mode" approval-wait "INJECTEDMODE" --resolve-mode
else
  bad "the approval-wait read mutation did not land, so it proves nothing"
fi

# --- a valued option refuses an empty value in BOTH spellings ---------------
#
# The spaced form has always refused it through need_val. The `=` form splits to
# an empty string, so it needs the same check after the split, and the flags are
# DERIVED from the arms that carry one rather than listed here: a hand-kept list
# is how ten of these went untested when the arms were added.
echo
echo "=== a valued option refuses an empty value in its = spelling ==="

# valued_flags SCRIPT — every --flag whose `=` arm calls need_val.
valued_flags() {
  # Leading whitespace is [[:space:]], not spaces: lanes indents with tabs, and
  # a space-only pattern silently contributed none of its arms.
  sed -n 's/^[[:space:]]*--\([a-z-][a-z-]*\)=\*).*need_val.*/\1/p' "$SCRIPTS_SRC/$1" | sort -u
}

SCRIPTS_SRC="$SKILLS_SRC/orch/scripts"
empty_dir="$TMP_ROOT/empty-value"
fixture "$empty_dir"

total_flags=0
for script in lanes open-terminal oversee-watch; do
  script_flags=0
  for flag in $(valued_flags "$script"); do
    script_flags=$((script_flags + 1))
    total_flags=$((total_flags + 1))
    rc=0
    # lanes takes a subcommand before its options; the others take none. This is
    # each script's grammar, not part of the flag list being derived.
    case "$script" in
    lanes) out="$(run "$script" "$empty_dir" list "--$flag=")" || rc=$? ;;
    *) out="$(run "$script" "$empty_dir" "--$flag=")" || rc=$? ;;
    esac
    # lanes exits 1, the other two exit 2; what matters is that it refused and
    # said which flag, not which number it chose.
    if [ "$rc" -eq 0 ]; then
      bad "$script --$flag= is refused" "exited 0 instead of refusing"
    elif [ "${out#*"--$flag requires a value"}" = "$out" ]; then
      bad "$script --$flag= names the flag" "got: $(printf '%s' "$out" | head -1)"
    else
      ok "$script --$flag= is refused and names the flag"
    fi
  done
  if [ "$script_flags" -gt 0 ]; then
    ok "$script contributed $script_flags valued flags to the sweep"
  else
    bad "$script contributed no valued flags" \
      "every one of its = arms would then be untested while the loop still passes"
  fi
done

# The sweep is worth nothing if the derivation quietly stops matching arms.
if [ "$total_flags" -ge 14 ]; then
  ok "$total_flags valued flags swept across the three CLIs"
else
  bad "the sweep found only $total_flags valued flags" \
    "the arms carry more than that, so the derivation stopped matching them"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
