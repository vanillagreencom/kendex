#!/usr/bin/env bash

# mutant_scripts NAME [FILE] — a must-fail control mutates a private copy of
# one script, never the shipped one. Every orch script finds its siblings and
# lib/ through its own directory without resolving a symlink, so a lone `cp`
# of dev-round-write dies on startup, and a control whose mutant never runs
# credits a pass to nothing. This builds $TMP_ROOT/NAME/scripts as real
# directories of symlinks to the shipped scripts, with FILE, a path relative
# to scripts/, the one private copy, which the caller mutates with
# mutate_file. With no FILE every entry is a link: the live scripts, placed
# where a stand-in such as the Linear CLI can sit beside their skill. The
# shipped scripts are the ones beside this tests/ directory, so a suite run
# from an installed layout mutates its own. Prints the scripts directory;
# callers need TMP_ROOT.
mutant_scripts() {
  local src dir="$TMP_ROOT/$1/scripts" entry
  src="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts" && pwd)" \
    || { printf 'mutant_scripts: no-scripts-dir %s\n' "${BASH_SOURCE[0]}" >&2; exit 1; }
  rm -rf "${TMP_ROOT:?}/$1"
  mkdir -p "$dir"
  while IFS= read -r entry; do
    if [[ -d "$src/$entry" ]]; then mkdir -p "$dir/$entry"
    else ln -s "$src/$entry" "$dir/$entry"; fi
  done < <(cd "$src" && find . -mindepth 1 | sed 's|^\./||')
  if [[ -n "${2:-}" ]]; then
    [[ -f "$src/$2" ]] || { printf 'mutant_scripts: no-such-script %s\n' "$2" >&2; exit 1; }
    rm -- "$dir/$2"
    cp -p -- "$src/$2" "$dir/$2"
  fi
  printf '%s\n' "$dir"
}

# mutate_file FILE OLD NEW — the substitution half of a must-fail control,
# asserted on both sides: OLD occurs exactly once in FILE before the edit and
# nowhere after it. A substitution that matched nothing would leave the control
# running the unmutated script, and a control that cannot fail proves only that
# its row ran. FILE is a private copy, mutant_scripts' FILE or the caller's
# own; a symlink is refused, since editing through it would rewrite the
# shipped script and editing around it would leave the mutant unmutated. The
# caller supplies assert_eq.
mutate_file() {
  local file="$1" old="$2" new="$3" name
  [[ ! -L "$file" ]] || { printf 'mutate_file: symlink %s\n' "$file" >&2; exit 1; }
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

# validate_run_dir DIR MODE [EXIT] [HEAD] [START] — a finished dev-validate-run
# run directory for a receipt to name: a start record under MODE, started at
# HEAD and at the epoch second START where each is given, a wall time of 3300
# seconds, and a sentinel recording EXIT, 0 by default; EXIT "none" leaves the
# run unfinished, with neither, and "no-verdict" records the bound ending it,
# as the runner's child does. The receipt reads it back through
# dev-validate-run --record, which dev_validate_run.sh pins against runs the
# script itself wrote. Prints DIR.
validate_run_dir() {
  mkdir -p "$1"
  printf 'validate-mode=%s\n' "$2" > "$1/start"
  [[ -z "${4:-}" ]] || printf 'head=%s\n' "$4" >> "$1/start"
  [[ -z "${5:-}" ]] || printf 'start=%s\n' "$5" >> "$1/start"
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

# round_run_dir DIR WORKTREE ISSUE RID [MODE] — a passing run started at the
# base_sha of WORKTREE's round record for ISSUE and RID, in the second the
# round was delegated, which is where and when a fix round's own run starts,
# so a fix receipt may name it. MODE is full by default. Prints DIR.
round_run_dir() {
  local base delegated_at
  base="$(jq -r '.base_sha' "$2/tmp/dev-round-$3-$4.json")" || return 1
  delegated_at="$(jq -r '.delegated_at' "$2/tmp/dev-round-$3-$4.json")" || return 1
  validate_run_dir "$1" "${5:-full}" 0 "$base" "$delegated_at"
}
