# shellcheck shell=bash
# Shared counters, runner and table driver for the preflight suites.
#
# Sourced on the line after each suite's `set -euo pipefail`; this file sets
# no mode, the caller's shell owns it. The suite keeps what is its own: `seed`
# (its neutral world), `TMP` and the trap that removes it, and `pf_world`, the
# map from a row's world words onto a fresh fixture in `$R`.
#
# Sourced, never executed: no mode bit, per this repo's CI convention.

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
run_pf() { # [args...] — run in $R; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$PF" "$@" 2>&1)" || RC=$?
}

# The finding heads in `$OUT`, in output order, one per line: the
# `path:line: [lane]` prefix of every line of that shape, never the message.
# A row compares this whole, so a fixture that also trips a neighbouring lane
# cannot pass on the finding it planted.
pf_fired() {
  printf '%s\n' "$OUT" | sed -n 's/^\([^ :][^ ]*:[0-9][0-9]*: \[[a-z-]*\]\).*/\1/p'
}

# `needs` is a tool the row's lane cannot run without: `shellcheck`, `jq`,
# or `toml` (taplo, or python3 with tomllib). Prints the reason it is
# absent; succeeds when it is present.
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
    *) printf 'a tool this driver does not know: %s\n' "$1" ;;
  esac
  return 0
}

# One table. Rows are `label|world|argv|needs|rc|fired|says`: `world` is a
# word list the suite's `pf_world` maps onto a fresh fixture (setting `R`),
# `argv` is `-` or the preflight flags, `needs` is `-` or a tool
# (`pf_needs_absent`), `rc` is exact, `fired` is the exact ordered
# `;`-separated list of finding heads the run must print (`-` for none),
# compared whole against `pf_fired`; a leading `~` makes it a containment pin
# (each listed head present, absent heads allowed), for a world whose
# incidental finding is ruled out of the row. `says` is `;`-separated
# fragments `$OUT` must carry, or `-`; it is the last field, so `read` keeps
# a `|` inside it. A row with an empty field asserts
# nothing and refuses the run; a world that cannot be built refuses it too;
# a table that asserted no row exits 2 from its own counter, so a fixture
# failure or a probe run never reads as green. `PF_TABLE_PROBE=1` renders
# each row's status, fired list and finding lines instead of asserting.
pf_table() {
  local title="$1" rows="$2" row label world argv needs rc fired says
  local field before reason got want head miss frag lines
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
    if [ "$needs" != - ] && reason="$(pf_needs_absent "$needs")"; then
      skipped "$label" "$reason"
      continue
    fi
    # shellcheck disable=SC2086
    pf_world $world || { printf 'the world could not be built: %s\n' "$row" >&2; exit 1; }
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
    case "$fired" in
      '~'*)
        want="${fired#'~'}"
        miss=""
        while IFS= read -r head; do
          [ -n "$head" ] || continue
          case ";$got;" in *";$head;"*) ;; *) miss="${miss:+$miss;}$head" ;; esac
        done <<EOF
$(printf '%s\n' "$want" | tr ';' '\n')
EOF
        if [ -n "$miss" ]; then
          bad "$label" "fired list lacks [$miss]; fired: $got"
          continue
        fi
        ;;
      *)
        if [ "$got" != "$fired" ]; then
          bad "$label" "want fired=$fired; got fired=$got"
          continue
        fi
        ;;
    esac
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
