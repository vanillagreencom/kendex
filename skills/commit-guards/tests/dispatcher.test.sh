#!/usr/bin/env bash
# Pins for scripts/commit-guards, the dispatcher: the batch runs exactly the
# checks COMMIT_GUARDS_CHECKS names, in order, each announced with the scope
# flag it takes (--all or --base REF to the full-scoped check, --staged to
# the staged-scoped ones, nothing to the rest), and aggregates fail-closed
# (any check that could not complete is exit 2 and named, any violation
# exit 1); a single check runs alone with its flags passed through; the
# check list and the scope flags are validated. Two tables: the batch,
# pinned by the exit status with every line the DISPATCHER prints (the
# step lines, the incompletion lines and the summary; a check's own lines
# are that check's suite's), and the single-check invocations, pinned by
# the exit status and the first line the named check printed.
#
# Marker words are assembled from split tokens so this file never contains
# a marker shape itself.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
GG="$SKILL_DIR/scripts/commit-guards"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# Hermetic: a leaked setting would change every batch below.
unset COMMIT_GUARDS_CHECKS COMMIT_GUARDS_TODO_EXCLUDES COMMIT_GUARDS_BYTE_CEILING_KB \
  COMMIT_GUARDS_BYTE_EXCLUDES COMMIT_GUARDS_SUPPRESSION_EXCLUDES \
  COMMIT_GUARDS_SUPPRESSION_BASELINE COMMIT_GUARDS_CONFLICT_EXCLUDES \
  COMMIT_GUARDS_COMMIT_TYPES COMMIT_GUARDS_PROSE_PATHS \
  COMMIT_GUARDS_MD_PATHS COMMIT_GUARDS_MD_REFS_PATHS COMMIT_GUARDS_MD_EXCLUDES COMMIT_GUARDS_MD_SCOPE \
  COMMIT_GUARDS_SETTINGS_FILE 2>/dev/null || true

TD="TO""DO"

PASS=0
FAIL=0
assert_eq() { # LABEL EXPECT ACTUAL
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"
  fi
}

# Two lines for a run in the row's repository under ENVS (comma-separated
# assignments) with ARGS: `batch` keeps the exit status and the dispatcher's
# own lines, in order, joined by ';'; `single` keeps the exit status and the
# first line printed. STDIN is fed to the run when given.
R=""
run_raw() { # ENVS ARGS [STDIN]
  local envs=()
  [ -z "$1" ] || IFS=',' read -ra envs <<<"$1"
  # shellcheck disable=SC2086
  (cd "$R" && printf '%b' "${3-}" | env ${envs[@]+"${envs[@]}"} "$GG" $2 2>&1)
}
batch() { # ENVS ARGS
  local rc=0 out=""
  out="$(run_raw "$1" "$2")" || rc=$?
  out="$(printf '%s\n' "$out" | LC_ALL=C grep -E '^(=== commit-guards:|commit-guards:|::error::commit-guards:)' || true)"
  printf 'rc=%s%s' "$rc" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}"
}
single() { # ENVS ARGS [STDIN]
  local rc=0 out=""
  out="$(run_raw "$1" "$2" "${3-}")" || rc=$?
  printf 'rc=%s%s' "$rc" "${out:+ $(printf '%s\n' "$out" | head -n 1)}"
}

# The lines the dispatcher prints, as functions of what a row asked for.
KNOWN="todo-ban byte-ceiling suppression-ban conflict-markers changelog-entries prose md-format md-refs comments commit-msg"
DEFAULT="todo-ban byte-ceiling suppression-ban conflict-markers changelog-entries prose md-format md-refs"
STAGED_SCOPED="todo-ban byte-ceiling md-format md-refs comments"
ERR="::error::commit-guards: "
steps() { # MODE CHECKS [INCOMPLETE] — one step line per check with its scope flag; the incompletion line after INCOMPLETE's step
  local mode="$1" c flag
  for c in $2; do
    flag=""
    case "$mode" in
      all) [ "$c" != byte-ceiling ] || flag=" --all" ;;
      staged) case " $STAGED_SCOPED " in *" $c "*) flag=" --staged" ;; esac ;;
      base:*) [ "$c" != byte-ceiling ] || flag=" --base ${mode#base:}" ;;
    esac
    printf '=== commit-guards: %s%s;' "$c" "$flag"
    [ "$c" != "${3-}" ] || printf "commit-guards: check '%s' did not complete (exit 2);" "$c"
  done
}
ok() { printf 'commit-guards: OK — enabled checks clean (%s)' "${1:-$DEFAULT}"; } # [CHECKS]
VIOLATIONS="commit-guards: violations — see the failures above"
INCOMPLETE="commit-guards: could not complete every check — fix the errors above before trusting any verdict"

# Fixture vocabulary. Every fixture builds its own repository; a name used
# twice is refused.
repo() { # NAME
  R="$TMP/$1"
  [ ! -e "$R" ] || { echo "harness: fixture $1 already exists" >&2; exit 2; }
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}
put() { mkdir -p "$R/$(dirname "$1")"; printf '%b' "$2" >"$R/$1"; git -C "$R" add -A; } # PATH CONTENT (printf %b), staged
commit() { git -C "$R" commit -qm "${1:-seed}"; }
clean() { repo "$1"; put ok.rs 'fn main() {}\n'; } # NAME — one clean staged file
planted() { clean "$1"; put planted.rs "// $TD: planted for the dispatcher\n"; } # NAME — a staged work marker
fx_settings_checks() { clean settings-checks; put kendex.settings.toml '[env]\nCOMMIT_GUARDS_CHECKS = "conflict-markers"\n'; }
fx_settings_bad() { clean settings-bad; put kendex.settings.toml '[env\nCOMMIT_GUARDS_CHECKS = "conflict-markers"\n'; } # an unclosed table header
staged_batch() { # NAME — a committed marker, and a staged change that adds none
  clean "$1"; commit; put fixture.rs "// $TD: committed in a fixture\n"; commit fixture
  # The staged lane reads a non-empty diff; what it prints about it is
  # its own suite's, so no row here can tell this change from none.
  printf 'fn other() {}\n' >>"$R/ok.rs"; git -C "$R" add ok.rs
}
fx_staged_md() { staged_batch staged-md; put doc.md 'Wrapped\ntext.\n'; }
full_scope() { repo "$1"; put big.txt "$(head -c 2048 /dev/zero | tr '\0' a)"; commit 'feat: seed'; git -C "$R" tag base; } # NAME — a committed 2 KB file, tagged base
grown() { full_scope "$1"; printf 'x' >>"$R/big.txt"; git -C "$R" add -A; commit 'feat: grow'; } # NAME — and one byte of growth since base

run_rows() { # label | fixture | envs | args | expect — through `batch`
  local row label fx envs args expect words
  for row in "$@"; do
    IFS='|' read -r label fx envs args expect <<<"$row"
    R=""
    read -ra words <<<"$fx"
    "${words[@]}"
    assert_eq "$label" "$expect" "$(batch "$envs" "$args")"
  done
}

echo "=== the batch runs the enabled checks in order and aggregates fail-closed ==="
BC=COMMIT_GUARDS_BYTE_CEILING_KB
run_rows \
  "a clean repository runs the eight default checks, byte-ceiling with --all, and reports them clean|clean clean-1|||rc=0 $(steps all "$DEFAULT")$(ok)" \
  "'all' is the same batch|clean clean-2||all|rc=0 $(steps all "$DEFAULT")$(ok)" \
  "one violating check makes the batch exit 1 after every check ran|planted planted-1|||rc=1 $(steps all "$DEFAULT")$VIOLATIONS" \
  "COMMIT_GUARDS_CHECKS narrows the batch: with byte-ceiling alone the planted marker is not judged|planted planted-2|COMMIT_GUARDS_CHECKS=byte-ceiling||rc=0 $(steps all byte-ceiling)$(ok byte-ceiling)" \
  "the check list resolves from kendex.settings.toml|fx_settings_checks|||rc=0 $(steps all conflict-markers)$(ok conflict-markers)" \
  "a check list that cannot be read is exit 2 before any check runs; the loader's own error is the only line|fx_settings_bad|||rc=2" \
  "a check outside the default batch runs when named, with its staged scope|clean comments-staged|COMMIT_GUARDS_CHECKS=comments|--staged|rc=0 $(steps staged comments)$(ok comments)" \
  "commit-msg in the batch list is exit 2 with the hook pointer|clean list-commit-msg|COMMIT_GUARDS_CHECKS=conflict-markers commit-msg||rc=2 ${ERR}commit-msg reads a message and cannot run in the batch; wire 'commit-guards commit-msg \"\$1\"' into the commit-msg hook instead" \
  "an unknown name in the check list is exit 2 naming the known set|clean list-unknown|COMMIT_GUARDS_CHECKS=conflict-markers no-such-check||rc=2 ${ERR}COMMIT_GUARDS_CHECKS names unknown check 'no-such-check' (known: $KNOWN)" \
  "a blank check list is exit 2|clean list-blank|COMMIT_GUARDS_CHECKS= ||rc=2 ${ERR}COMMIT_GUARDS_CHECKS resolved empty — name at least one check or unset it" \
  "a check that exits 2 is named as incomplete, the batch still runs the rest and exits 2|clean incomplete|$BC=abc||rc=2 $(steps all "$DEFAULT" byte-ceiling)$INCOMPLETE" \
  "a batch carrying a violation and an incomplete check reports the incompletion, not the violations|planted planted-3|$BC=abc||rc=2 $(steps all "$DEFAULT" byte-ceiling)$INCOMPLETE" \
  "'all' with a flag a check would take is exit 2: flags go to a single check|clean all-extra||all --extra|rc=2 ${ERR}'all' takes only --staged or --base REF; invoke a single check to pass flags"

echo "=== --staged and --base REF name the batch's scope; each check gets the flag it takes ==="
run_rows \
  "'all --staged' hands --staged to the staged-scoped checks and no other, so a commit adding no marker passes|staged_batch staged-1||all --staged|rc=0 $(steps staged "$DEFAULT")$(ok)" \
  "control: a hard-wrapped markdown file staged beside the code fails the staged batch|fx_staged_md||all --staged|rc=1 $(steps staged "$DEFAULT")$VIOLATIONS" \
  "'--staged' without 'all' is the same batch|staged_batch staged-2||--staged|rc=0 $(steps staged "$DEFAULT")$(ok)" \
  "control: the index-wide batch still refuses the committed marker|staged_batch staged-3|||rc=1 $(steps all "$DEFAULT")$VIOLATIONS" \
  "a check outside the staged-scoped set runs unflagged under --staged|staged_batch staged-4|COMMIT_GUARDS_CHECKS=conflict-markers|all --staged|rc=0 $(steps staged conflict-markers)$(ok conflict-markers)" \
  "'all' hands byte-ceiling --all, so a committed oversized file fails the full batch|full_scope full-1|$BC=1,COMMIT_GUARDS_CHECKS=byte-ceiling|all|rc=1 $(steps all byte-ceiling)$VIOLATIONS" \
  "control: 'all --staged' hands byte-ceiling --staged and judges only the staged diff|full_scope full-2|$BC=1,COMMIT_GUARDS_CHECKS=byte-ceiling|all --staged|rc=0 $(steps staged byte-ceiling)$(ok byte-ceiling)" \
  "'all --base REF' hands byte-ceiling --base REF, so growth since the base fails|grown base-1|$BC=1,COMMIT_GUARDS_CHECKS=byte-ceiling|all --base base|rc=1 $(steps base:base byte-ceiling)$VIOLATIONS" \
  "--base=REF without 'all' is the same scope|grown base-2|$BC=1,COMMIT_GUARDS_CHECKS=byte-ceiling|--base=base|rc=1 $(steps base:base byte-ceiling)$VIOLATIONS" \
  "a check outside the full-scoped set runs unflagged under --base|grown base-3|COMMIT_GUARDS_CHECKS=conflict-markers|all --base base|rc=0 $(steps base:base conflict-markers)$(ok conflict-markers)" \
  "'--base' without a ref is exit 2|grown base-4||all --base|rc=2 ${ERR}--base requires a ref" \
  "'--staged' with '--base' is exit 2: one scope per batch|grown base-5||all --staged --base base|rc=2 ${ERR}--staged and --base name different scopes; pass one" \
  "an unknown base ref is a check that could not complete|grown base-6|COMMIT_GUARDS_CHECKS=byte-ceiling|all --base no-such-ref|rc=2 $(steps base:no-such-ref byte-ceiling byte-ceiling)$INCOMPLETE"

echo "=== a single check runs alone, flags and exit status passed through; a batch announces before the check speaks ==="
single_rows() { # label | fixture | envs | args | stdin | expect — through `single`
  local row label fx envs args stdin expect words
  for row in "$@"; do
    IFS='|' read -r label fx envs args stdin expect <<<"$row"
    R=""
    read -ra words <<<"$fx"
    "${words[@]}"
    assert_eq "$label" "$expect" "$(single "$envs" "$args" "$stdin")"
  done
}
single_rows \
  "a single check runs alone with its own output|clean single-1||todo-ban||rc=0 todo-ban: OK — no work markers in tracked files" \
  "flags pass through to the named check|clean single-2|$BC=7|byte-ceiling --all||rc=0 byte-ceiling: OK — 1 tracked file(s) (full sweep) checked, ceiling 7 KB" \
  "the step line precedes the check's own output: a batch's first line is the announcement|clean order-1|COMMIT_GUARDS_CHECKS=conflict-markers|||rc=0 === commit-guards: conflict-markers" \
  "control: the named check's exit status is the run's|planted single-3||todo-ban||rc=1 todo-ban FAIL work marker: planted.rs:1:// $TD: planted for the dispatcher" \
  "commit-msg is invocable by name over stdin: only the batch refuses it|clean single-4||commit-msg|feat: dispatched\n|rc=0 commit-msg: OK — conventional header: feat: dispatched" \
  "an unknown check name is exit 2 naming the known set|clean single-5||no-such-check||rc=2 ${ERR}unknown check 'no-such-check' (known: $KNOWN)" \
  "--help prints usage at exit 0|clean help||--help||rc=0 usage: commit-guards [all] [--staged | --base REF] | CHECK [ARGS...]" \
  "-h is --help|clean help-h||-h||rc=0 usage: commit-guards [all] [--staged | --base REF] | CHECK [ARGS...]"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
