# shellcheck shell=bash
# Shared counters, runner and table driver for the preflight suites.
#
# Sourced on the line after each suite's `set -euo pipefail`; this file sets
# no mode, the caller's shell owns it. The suite keeps what is its own: its
# neutral world, `TMP` and the trap that removes it, and `pf_world`, the map
# from a row's world words onto a fresh fixture in `$R`. `pf_scope_seed` is
# here because the two scope suites, split from one file, share one world.
#
# Sourced, never executed: no mode bit, per this repo's CI convention.

# `pf_scope_seed` builds every world with `git -C`, and an exported GIT_DIR,
# GIT_COMMON_DIR, GIT_WORK_TREE or GIT_INDEX_FILE takes precedence over it: a
# caller carrying one would aim these fixtures at its own repository. Cleared
# here for the suites that source this file, per skills/AGENTS.md.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

PF="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts" && pwd)/preflight"

PASS=0
FAIL=0
SKIP=0
ok() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"
}
# A row whose tool is absent is neither passed nor failed: a control that
# never ran is not evidence, and a tally that hid it would read as coverage.
skipped() {
  SKIP=$((SKIP + 1))
  printf '  skip  %s (%s)\n' "$1" "$2"
}

OUT=""
RC=0
# The directory the run starts in. Empty means the fixture itself; a world
# that pins how preflight finds a repository the caller is not standing in
# sets it to a directory outside `$R`, and `pf_table` clears it per row.
PF_CWD=""
run_pf() { # [args...] — run in ${PF_CWD:-$R}; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "${PF_CWD:-$R}" && "$PF" "$@" 2>&1)" || RC=$?
}

# The finding heads in `$OUT`, in output order, one per line: the
# `path:line: [lane]` prefix of every line of that shape, never the message.
# A row compares this whole, so a fixture that also trips a neighbouring lane
# cannot pass on the finding it planted. The contract is the paths every
# fixture here produces: a head whose path carries a space is not read, so a
# row over such a path would see an empty list rather than its finding.
pf_fired() {
  printf '%s\n' "$OUT" | sed -n 's/^\([^ :][^ ]*:[0-9][0-9]*: \[[a-z-]*\]\).*/\1/p'
}

# The only judge of which `needs` tokens exist: a tool the row's lane cannot
# run without (`shellcheck`, `jq`, or `toml` — taplo, or python3 with
# tomllib), or `nonroot`, the reader a permission fixture needs in order to be
# denied. Three outcomes, so a mistyped token cannot read as an absent tool
# and silently drop the row: `0` what the row named is absent, printing the
# reason (the row skips); `1` it is present (the row runs); `2` the token is
# not a name this driver knows, printing that (the run refuses).
pf_needs_absent() { # NEEDS
  case "$1" in
    shellcheck | jq)
      command -v "$1" >/dev/null 2>&1 && return 1
      printf '%s not on PATH\n' "$1"
      ;;
    toml)
      command -v taplo >/dev/null 2>&1 && return 1
      command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' >/dev/null 2>&1 && return 1
      printf 'no taplo and no python3 with tomllib\n'
      ;;
    nonroot)
      case "$(id -u)" in 0) ;; *) return 1 ;; esac
      printf 'running as root, where chmod 000 denies nothing\n'
      ;;
    *)
      printf 'a tool this driver does not know: %s\n' "$1"
      return 2
      ;;
  esac
  return 0
}

# The neutral world the two scope suites share: a committed baseline whose
# `docs/legacy.md` already carries a dead citation, so `--all` reaches a
# violation the default scope cannot; an `origin/main` for the default base
# walk to resolve; an applied migration; and a feature branch checked out. It
# is rebuilt on every call, so a world word two rows both name starts clean.
pf_scope_seed() { # NAME — fixture in $R
  R="$TMP/$1"
  rm -rf -- "${TMP:?}/$1" "${TMP:?}/$1.git"
  mkdir -p "$R/docs" "$R/store/migrations"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  printf '# Staged\n' >"$R/docs/staged.md"
  printf '# Loose\n' >"$R/docs/loose.md"
  printf '# Legacy\n\nSee `docs/gone.md` for background.\n' >"$R/docs/legacy.md"
  printf 'CREATE TABLE t (id INTEGER);\n' >"$R/store/migrations/V1__init.sql"
  git -C "$R" add -A
  git -C "$R" commit -qm init
  git clone -q --bare "$R" "$R.git"
  git -C "$R" remote add origin "$R.git"
  git -C "$R" fetch -q origin
  git -C "$R" remote set-head origin main >/dev/null
  git -C "$R" checkout -qb feature
}

# One table. Rows are `label|world|argv|needs|rc|fired|says`: `world` is a
# word list the suite's `pf_world` maps onto a fresh fixture (setting `R`),
# `argv` is `-` or the preflight flags, `needs` is `-` or a token
# (`pf_needs_absent`), `rc` is exact, `fired` is the exact ordered
# `;`-separated list of finding heads the run must print (`-` for none),
# compared whole against `pf_fired`. `says` is `;`-separated fragments `$OUT`
# must carry, or `-`; it is the last field, so `read` keeps a `|` inside it.
# A `{R}` in `argv` expands to the fixture path, which the row cannot spell
# before its world is built. A row with an empty field asserts nothing and
# refuses the run, as does a `needs` token `pf_needs_absent` does not know, a
# world word `pf_world` does not know or any failure its return status
# carries; a table that asserted no row exits 2 from its own counter, so a
# fixture failure or a probe run never reads as green. `PF_TABLE_PROBE=1`
# renders each row's status, fired list and finding lines instead of
# asserting.
pf_table() {
  local title="$1" rows="$2" row label world argv needs rc fired says
  local field before reason needs_rc got miss frag lines brace_r
  before=$((PASS + FAIL))
  printf '=== %s ===\n' "$title"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS='|' read -r label world argv needs rc fired says <<EOF
$row
EOF
    for field in "$label" "$world" "$argv" "$needs" "$rc" "$fired" "$says"; do
      [ -n "$field" ] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    if [ "$needs" != - ]; then
      # The status branched on is the substitution's own: `if cmd; then`
      # cannot tell the absent tool from the token this driver does not know.
      needs_rc=0
      reason="$(pf_needs_absent "$needs")" || needs_rc=$?
      case "$needs_rc" in
        0) skipped "$label" "$reason"; continue ;;
        1) ;; # the tool is present, so the row runs
        *) printf '%s: %s\n' "$reason" "$row" >&2; exit 1 ;;
      esac
    fi
    PF_CWD=""
    # shellcheck disable=SC2086
    pf_world $world || { printf 'the world could not be built: %s\n' "$row" >&2; exit 1; }
    brace_r='{R}'
    argv="${argv//$brace_r/$R}"
    # `says` takes the same substitution, so a row can pin a VALUE the fixture
    # path supplies. Without it a row could only pin the key half of a
    # `key=value` line and would pass while the value regressed.
    says="${says//$brace_r/$R}"
    if [ "$argv" = - ]; then
      run_pf
    else
      # shellcheck disable=SC2086
      run_pf $argv
    fi
    got="$(pf_fired | tr '\n' ';')"
    got="${got%;}"
    [ -n "$got" ] || got="-"
    if [ "${PF_TABLE_PROBE:-}" = 1 ]; then
      lines="$(printf '%s\n' "$OUT" | grep -E '^[^ :][^ ]*:[0-9]+: \[[a-z-]+\]' || :)"
      printf '%s => rc=%s fired=%s\n%s\n' "$label" "$RC" "$got" "${lines:-  (no finding line)}"
      continue
    fi
    if [ "$RC" != "$rc" ]; then
      bad "$label" "want rc=$rc; got rc=$RC fired=$got: $(printf '%s' "$OUT" | tr '\n' ' ')"
      continue
    fi
    if [ "$got" != "$fired" ]; then
      bad "$label" "want fired=$fired; got fired=$got"
      continue
    fi
    miss=""
    if [ "$says" != - ]; then
      while IFS= read -r frag; do
        [ -n "$frag" ] || continue
        case "$OUT" in *"$frag"*) ;; *) miss="${miss:+$miss;}$frag" ;; esac
      done <<EOF
$(printf '%s\n' "$says" | tr ';' '\n')
EOF
    fi
    if [ -n "$miss" ]; then
      bad "$label" "expected the output to carry '$miss': $(printf '%s' "$OUT" | tr '\n' ' ')"
    else
      ok "$label"
    fi
  done <<EOF
$rows
EOF
  [ "$((PASS + FAIL))" -gt "$before" ] || {
    printf 'no row was asserted (a probe run renders rows instead)\n' >&2
    exit 2
  }
}

# The tally. A suite that asserted nothing is not a passing suite: a table
# whose rows never ran would otherwise report `0 passed, 0 failed` and exit 0.
pf_summary() {
  printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
  if [ "$((PASS + FAIL))" -eq 0 ]; then
    printf '%s: asserted nothing\n' "$(basename "$0")" >&2
    return 2
  fi
  [ "$FAIL" -eq 0 ]
}
