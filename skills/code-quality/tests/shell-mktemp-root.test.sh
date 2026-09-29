#!/usr/bin/env bash
# The shell mktemp-root rule is prose: no guard lane judges a suite's scratch
# root, because whether a later comparison reads a path derived from the root
# is a data-flow question a text scan cannot answer (skills/AGENTS.md states
# the choice). So this suite holds the prose to its spelling and its behaviour
# instead. ../SKILL.md § Language Discipline must carry the four prescribed
# lines and, in the catalog tree, the shell-suite rules beside it must cite that
# section; neither may carry the hazard line, `mktemp -d` nested inside `cd`.
# The lines SKILL.md fences are then run from inside a scratch caller
# directory, with a working and with a failing `mktemp`: they exit non-zero on
# the failure and the caller directory survives every row. The nested shape
# itself is a text pattern, so a last row scans every tracked file of the
# repository holding this suite for it. Each judge takes a control on a mutant
# copy or a scratch repository.
#
# Run: bash skills/code-quality/tests/shell-mktemp-root.test.sh
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
CATALOG_RULES="$SKILL_DIR/../AGENTS.md"

# The spelling SKILL.md carries, held literally so a rewording that drops a
# check, the `--` or the `:?` turns the row red.
PRESCRIBED_LINES='TMP_ROOT="$(mktemp -d)" || { echo "NAME: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "NAME: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "NAME: scratch=resolve-failed" >&2; exit 1; }
trap '"'"'rm -rf -- "${TMP_ROOT:?}"'"'"' EXIT'
# The line a failed mktemp turns into the caller's directory. Assembled from
# MKTEMP so this suite's own source never matches the tree scan below, which
# then needs no exclusion.
MKTEMP='mktemp -d'
HAZARD_LINE="TMP_ROOT=\"\$(cd \"\$($MKTEMP)\" && pwd -P)\""
# The nested shape the tree scan refuses, in both the `cd` and `cd --`
# spellings, as a git grep extended regex.
NESTED_ERE='cd (-- )?"?[$][(]mktemp -d'
# The link the catalog's shell-suite rules cite the prescribed lines through.
CITATION='(code-quality/SKILL.md#language-discipline)'

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}" >&2; }

TMP_ROOT="$(mktemp -d)" || { echo "shell-mktemp-root: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "shell-mktemp-root: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "shell-mktemp-root: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# judge_text FILE NEEDLES: 0 when FILE carries every line of NEEDLES and not
# the hazard line, 1 when a needle is missing, 3 when the hazard line is
# present, 2 when FILE cannot be read.
judge_text() {
  local file="$1" needles="$2" text line
  text="$(cat -- "$file")" || return 2
  case "$text" in
    *"$HAZARD_LINE"*) return 3 ;;
  esac
  while IFS= read -r line; do
    case "$text" in
      *"$line"*) ;;
      *) return 1 ;;
    esac
  done <<LINES_EOF
$needles
LINES_EOF
  return 0
}

# fenced_root_lines FILE: print the one ```bash fence in FILE that makes a
# `mktemp -d` root, its list indent stripped; exit 1 unless exactly one fence
# does.
fenced_root_lines() {
  awk '
    /^[ \t]*```bash[ \t]*$/ { infence = 1; body = ""; match($0, /^[ \t]*/); ind = RLENGTH; next }
    infence && /^[ \t]*```[ \t]*$/ {
      infence = 0
      if (body ~ /mktemp -d/) { found++; keep = body }
      next
    }
    infence { body = body substr($0, ind + 1) "\n" }
    END { if (found != 1) exit 1; printf "%s", keep }
  ' "$1"
}

# The mktemp each row puts first on PATH; `real` puts none. `fail-empty` is how
# GNU and BSD mktemp fail. `fail-dot` fails with `.` on stdout, the argument
# `cd` accepts on every bash, so the hazard control reddens on bash 5.3, which
# refuses `cd ""`. `not-a-dir` answers a path that is a regular file.
write_stub() {
  local dir="$1" mode="$2"
  mkdir -p -- "$dir"
  case "$mode" in
    real) return 0 ;;
    fail-empty) printf '#!/bin/sh\necho "mktemp: failed to create directory" >&2\nexit 1\n' > "$dir/mktemp" ;;
    fail-dot) printf '#!/bin/sh\necho .\nexit 1\n' > "$dir/mktemp" ;;
    not-a-dir) printf '#!/bin/sh\n: > "$TMPDIR/plain-file"\necho "$TMPDIR/plain-file"\n' > "$dir/mktemp" ;;
    *) echo "UNKNOWN-MODE: $mode" >&2; exit 2 ;;
  esac
  chmod +x "$dir/mktemp"
}

# run_lines DOC MODE: run DOC's fenced lines under `set -euo pipefail` with
# NAME as `probe`, from a fresh caller directory holding a sentinel, and judge
# the row. TMPDIR is reached through a symlink so the root GNU mktemp spells
# differs from its resolved form, the case the resolution exists for. BSD
# mktemp on macOS ignores TMPDIR and answers under `/var`, itself a symlink,
# so the `real` row judges the root's parent resolved wherever mktemp put it.
ROW=0
# REMOVED counts rows whose caller directory did not survive; control 3 reads it.
REMOVED=0
# UNRESOLVED counts rows whose root was not resolved; control 5 reads it.
UNRESOLVED=0
run_lines() {
  local doc="$1" mode="$2" want_status="$3" want_key="$4"
  local lines row caller stub tmpdir out err status last root parent resolved
  ROW=$((ROW + 1))
  row="$TMP_ROOT/run-$ROW"
  caller="$row/caller"
  stub="$row/stub"
  tmpdir="$row/tmp-real"
  mkdir -p -- "$caller" "$tmpdir"
  : > "$caller/sentinel"
  ln -s -- "$tmpdir" "$row/tmp-link"
  write_stub "$stub" "$mode"
  if ! lines="$(fenced_root_lines "$doc")"; then
    fail "$mode: no single mktemp fence to run in $doc"
    return 0
  fi
  lines="${lines//NAME/probe}"
  status=0
  (cd -- "$caller" && env -i PATH="$stub:$PATH" HOME="$row" TMPDIR="$row/tmp-link" \
    "$BASH" -c "set -euo pipefail
$lines
printf 'root=%s\n' \"\$TMP_ROOT\"" >"$row/out" 2>"$row/err") || status=$?
  out="$(cat -- "$row/out")" || { fail "$mode: stdout unreadable" "$row/out"; return 0; }
  err="$(cat -- "$row/err")" || { fail "$mode: stderr unreadable" "$row/err"; return 0; }
  # A failing mktemp prints its own diagnostic first; the refusal is the last
  # line the prescribed lines print.
  last="${err##*$'\n'}"

  if [[ ! -e $caller/sentinel ]]; then
    REMOVED=$((REMOVED + 1))
    fail "$mode: the caller directory was removed" "$doc"
    return 0
  fi
  if [[ $status -ne $want_status ]]; then
    fail "$mode: exit $status, want $want_status" "stderr: $err"
    return 0
  fi
  case "$want_key" in
    -)
      root="${out#root=}"
      parent="${root%/*}"
      case "$root" in
        /*/?*) ;;
        *) fail "$mode: root is not an absolute path below /" "stdout: $out"; return 0 ;;
      esac
      if ! resolved="$(cd -- "$parent" && pwd -P)"; then
        fail "$mode: the root's parent cannot be resolved" "stdout: $out"
        return 0
      fi
      if [[ $resolved != "$parent" ]]; then
        UNRESOLVED=$((UNRESOLVED + 1))
        fail "$mode: root not resolved, its parent resolves to $resolved" "stdout: $out"
        return 0
      fi
      if [[ -e $root ]]; then
        fail "$mode: the EXIT trap left the root" "$root"
        return 0
      fi
      ;;
    *)
      case "$last" in
        "$want_key"*) ;;
        *) fail "$mode: last stderr line is not $want_key" "stderr: $err"; return 0 ;;
      esac
      ;;
  esac
  pass "$mode: exit $want_status, caller kept: $doc"
}

# MODE WANT_STATUS WANT_KEY: `-` expects no refusal, a resolved root, and the
# trap to remove it.
RUN_ROWS='real 0 -
fail-empty 1 probe: scratch=mktemp-failed
fail-dot 1 probe: scratch=mktemp-failed
not-a-dir 1 probe: scratch=not-a-directory value=['

# judge_doc DOC: every row for one document. Prints nothing itself; the rows
# report through pass/fail.
judge_doc() {
  local doc="$1" mode want_status want_key
  while read -r mode want_status want_key; do
    [ -n "$mode" ] || continue
    run_lines "$doc" "$mode" "$want_status" "$want_key"
  done <<ROWS_EOF
$RUN_ROWS
ROWS_EOF
}

# scan_tree ROOT: print each tracked file:line under ROOT carrying the nested
# shape; 0 when none does, 1 when one does, 2 when the scan failed.
scan_tree() {
  local root="$1" out status=0 hit
  out="$(git -C "$root" grep -n -I -E -e "$NESTED_ERE" --)" || status=$?
  case "$status" in
    0)
      while IFS= read -r hit; do
        printf '%s\n' "${hit%%:*}:$(printf '%s' "${hit#*:}" | cut -d: -f1)"
      done <<HITS_EOF
$out
HITS_EOF
      return 1
      ;;
    1) return 0 ;;
    *) return 2 ;;
  esac
}

# --- rows: the skill carries the lines, the catalog rules cite them ----------
status=0
judge_text "$SKILL_DIR/SKILL.md" "$PRESCRIBED_LINES" || status=$?
if [ "$status" -eq 0 ]; then
  pass "names the checked root lines: $SKILL_DIR/SKILL.md"
else
  fail "does not name the checked root lines (status $status): $SKILL_DIR/SKILL.md" "expected every line of: $PRESCRIBED_LINES"
fi
judge_doc "$SKILL_DIR/SKILL.md"

# The catalog's shell-suite rules sit beside the skill only in the source tree;
# an installed copy has no sibling AGENTS.md, and the row says so rather than
# passing on nothing.
if [ -f "$CATALOG_RULES" ]; then
  status=0
  judge_text "$CATALOG_RULES" "$CITATION" || status=$?
  if [ "$status" -eq 0 ]; then
    pass "cites the checked root lines: $CATALOG_RULES"
  else
    fail "does not cite the checked root lines (status $status): $CATALOG_RULES" "expected the link $CITATION and no hazard line"
  fi
else
  printf '  note  catalog rules not judged: no AGENTS.md beside %s (installed copy)\n' "$SKILL_DIR"
fi

# The tree scan runs where a git work tree tracks this suite, from that tree's
# root. An installed copy no work tree tracks says so rather than passing on
# nothing; a tracked suite whose scan fails is a failure, never a clean tree.
SUITE_FILE="$(basename -- "${BASH_SOURCE[0]}")"
if git -C "$TEST_DIR" ls-files --error-unmatch -- "$SUITE_FILE" >/dev/null 2>&1; then
  if ! REPO_ROOT="$(git -C "$TEST_DIR" rev-parse --show-toplevel)"; then
    fail "tree scan: the work tree tracking $SUITE_FILE names no top level" "$TEST_DIR"
  else
    status=0
    hits="$(scan_tree "$REPO_ROOT")" || status=$?
    case "$status" in
      0) pass "tree scan: no tracked file under $REPO_ROOT nests mktemp -d inside cd" ;;
      1) fail "tree scan: tracked files nest mktemp -d inside cd" "$(printf '%s\n' "$hits" | tr '\n' ' ')" ;;
      *) fail "tree scan: git grep failed (status $status)" "$REPO_ROOT" ;;
    esac
  fi
else
  printf '  note  tree not scanned: no git work tree tracks %s (installed copy)\n' "$TEST_DIR/$SUITE_FILE"
fi

# --- controls: each judge turns red on a mutant copy of SKILL.md -------------
MUTANTS="$TMP_ROOT/mutants"
mkdir -p -- "$MUTANTS"

# Control 1, a prescribed line removed: the resolve line and the prose that
# names `pwd -P` both go.
mutant="$MUTANTS/no-resolve.md"
before="$(grep -c -F -- 'pwd -P' "$SKILL_DIR/SKILL.md")" || before=0
grep -v -F -- 'pwd -P' "$SKILL_DIR/SKILL.md" > "$mutant" || true
after="$(grep -c -F -- 'pwd -P' "$mutant")" || after=0
status=0
judge_text "$mutant" "$PRESCRIBED_LINES" || status=$?
if [ "$before" -lt 1 ]; then
  fail "control could not plant its defect" "SKILL.md holds no 'pwd -P' line to remove"
elif [ "$after" -ne 0 ]; then
  fail "control mutant still carries the rule" "before=$before after=$after"
elif [ "$status" -ne 1 ]; then
  fail "control: the spelling judge answered $status on a copy with the resolve line removed, want 1" "$mutant"
else
  pass "control: the spelling judge refuses a copy with the resolve line removed"
fi

# Control 2, the hazard line added back beside the prescribed lines.
mutant="$MUTANTS/hazard-beside.md"
{ cat -- "$SKILL_DIR/SKILL.md"; printf '\n%s\n' "$HAZARD_LINE"; } > "$mutant"
status=0
judge_text "$mutant" "$PRESCRIBED_LINES" || status=$?
if [ "$status" -ne 3 ]; then
  fail "control: the spelling judge answered $status on a copy carrying the hazard line, want 3" "$mutant"
else
  pass "control: the spelling judge refuses a copy carrying the hazard line"
fi

# Control 3, the fence's first three lines replaced by the hazard line: the
# fence still makes a mktemp root and keeps its trap, so a failing mktemp row
# must report the caller directory removed.
mutant="$MUTANTS/hazard-fence.md"
awk -v hazard="$HAZARD_LINE" '
  /^[ \t]*```bash[ \t]*$/ { infence = 1; match($0, /^[ \t]*/); ind = substr($0, 1, RLENGTH); print; next }
  infence && /^[ \t]*```[ \t]*$/ { infence = 0; print; next }
  infence && /mktemp -d|! -L|pwd -P/ { if (!done) { print ind hazard; done = 1; planted++ } next }
  { print }
  END { if (planted != 1) exit 1 }
' "$SKILL_DIR/SKILL.md" > "$mutant" || { fail "control could not plant the hazard fence" "$mutant"; mutant=""; }
if [ -n "$mutant" ]; then
  before_fail="$FAIL"
  before_pass="$PASS"
  REMOVED=0
  judge_doc "$mutant" >/dev/null 2>&1
  PASS="$before_pass"
  FAIL="$before_fail"
  if [ "$REMOVED" -lt 1 ]; then
    fail "control: the run judge reported no caller removed for a fence carrying the hazard line" "$mutant"
  else
    pass "control: the run judge reports the caller removed for a fence carrying the hazard line ($REMOVED rows)"
  fi
fi

# Control 4, the nested shape planted in both spellings in a scratch
# repository: the tree scan must name each planted file:line.
CONTROL_REPO="$TMP_ROOT/scan-control"
mkdir -p -- "$CONTROL_REPO"
git -C "$CONTROL_REPO" init -q
git -C "$CONTROL_REPO" config gc.auto 0
git -C "$CONTROL_REPO" config maintenance.auto false
{
  printf '#!/usr/bin/env bash\n'
  printf '%s\n' "$HAZARD_LINE"
  printf '%s\n' "${HAZARD_LINE/cd /cd -- }"
} > "$CONTROL_REPO/planted.sh"
git -C "$CONTROL_REPO" add -- planted.sh
status=0
hits="$(scan_tree "$CONTROL_REPO")" || status=$?
want="planted.sh:2
planted.sh:3"
if [ "$status" -ne 1 ]; then
  fail "control: the tree scan answered $status on a repository with the nested shape planted, want 1" "$CONTROL_REPO"
elif [ "$hits" != "$want" ]; then
  fail "control: the tree scan named the wrong lines" "got: $(printf '%s' "$hits" | tr '\n' ' ') want: $(printf '%s' "$want" | tr '\n' ' ')"
else
  pass "control: the tree scan names each planted line in both spellings"
fi

# Control 5, the resolve line removed from the fence (control 1's mutant): the
# `real` row must report the root not resolved, on GNU and BSD mktemp alike.
mutant="$MUTANTS/no-resolve.md"
before_fail="$FAIL"
before_pass="$PASS"
UNRESOLVED=0
run_lines "$mutant" real 0 - >/dev/null 2>&1
PASS="$before_pass"
FAIL="$before_fail"
if [ "$UNRESOLVED" -ne 1 ]; then
  fail "control: the run judge did not report the root unresolved for a fence without the resolve line" "$mutant"
else
  pass "control: the run judge reports the root unresolved for a fence without the resolve line"
fi

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
