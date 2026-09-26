#!/usr/bin/env bash

# A must-fail control mutates a private copy of a script, never the shipped
# one. dev-round-write, dev-return-write and dev-artifact-check each source
# lib/branch-growth.sh from their own directory, so a lone `cp` of one of them
# produces a mutant that dies on startup — and a control whose mutant never
# runs credits a pass to nothing. Copy the whole scripts/ tree instead and take
# the mutant from inside it. Prints the copied scripts directory; callers need
# REPO_ROOT and TMP_ROOT.
copy_scripts() {
  local name="$1"
  local dir="$TMP_ROOT/$name"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -R "$REPO_ROOT/skills/orch/scripts" "$dir/"
  printf '%s\n' "$dir/scripts"
}

# mutate_file FILE OLD NEW — the substitution half of a must-fail control,
# asserted on both sides: OLD occurs exactly once in FILE before the edit and
# nowhere after it. A substitution that matched nothing would leave the control
# running the unmutated script, and a control that cannot fail proves only that
# its row ran. The caller copies the script first, by copy_scripts above or its
# own copy, and supplies assert_eq.
mutate_file() {
  local file="$1" old="$2" new="$3" name
  name="$(basename "$file")"
  assert_eq "$(grep -c -F -e "$old" "$file" || true)" "1" \
    "control finds exactly one site to mutate in $name"
  perl -i -pe 'BEGIN { ($o, $n) = (shift, shift) } s/\Q$o\E/$n/g' "$old" "$new" "$file"
  assert_eq "$(grep -c -F -e "$old" "$file" || true)" "0" \
    "control applied its mutation in $name"
}

init_growth_state() {
  local state="$1" worktree="$2" issue="$3" round_id="$4"
  local exclude

  exclude="$(git -C "$worktree" rev-parse --path-format=absolute --git-path info/exclude)"
  grep -Fxq 'tmp/' "$exclude" 2>/dev/null || printf 'tmp/\n' >> "$exclude"
  "$state" --state-dir "$worktree/tmp" init "$issue" --worktree "$worktree" --branch test >/dev/null
  "$state" --state-dir "$worktree/tmp" set "$issue" dev_round_id "$round_id" >/dev/null
}

growth_round_write() {
  local state="$1" writer="$2" worktree="" issue="" round_id="" arg previous=""
  shift 2
  for arg in "$@"; do
    case "$previous" in
      --worktree) worktree="$arg" ;;
      --issue) issue="$arg" ;;
      --round-id) round_id="$arg" ;;
    esac
    previous="$arg"
  done
  if [[ -n "$worktree" && -n "$issue" && -n "$round_id" && -f "$worktree/tmp/workflow-state-$issue.json" ]]; then
    "$state" --state-dir "$worktree/tmp" set "$issue" dev_round_id "$round_id" >/dev/null
  fi
  env ORCH_STATE_DIR="$worktree/tmp" "$writer" "$@"
}

# validate_run_dir DIR MODE [EXIT] — a finished dev-validate-run run directory
# for a receipt to name: a start record under MODE, a wall time of 3300
# seconds, and a sentinel recording EXIT, 0 by default; EXIT "none" leaves the
# run unfinished, with neither, and "no-verdict" records the bound ending it,
# as the runner's child does. The receipt reads it back through
# dev-validate-run --record, which dev_validate_run.sh pins against runs the
# script itself wrote. Prints DIR.
validate_run_dir() {
  mkdir -p "$1"
  printf 'validate-mode=%s\n' "$2" > "$1/start"
  if [[ "${3:-0}" != none ]]; then
    printf 'started-at=2026-01-01T00:00:00Z\nended-at=2026-01-01T00:55:00Z\nseconds=3300\n' > "$1/timing"
  fi
  case "${3:-0}" in
    none) ;;
    no-verdict) printf 'guard-exit=124 at=2026-01-01T00:55:00Z verdict=no-verdict\n' > "$1/exit" ;;
    *) printf 'guard-exit=%s at=2026-01-01T00:55:00Z\n' "${3:-0}" > "$1/exit" ;;
  esac
  printf '%s\n' "$1"
}
