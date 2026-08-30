#!/usr/bin/env bash
# vacuous-suite-scan: absence-subject
# orch's scripts run wherever an orchestrator runs, and `skills/orch/SKILL.md`
# § System dependencies declares `bash` 3.2 — macOS system bash. So a shipped
# orch script may not use a Bash 4+ builtin or syntax: mapfile/readarray,
# associative arrays, automatic FD-allocation redirections, case-conversion
# expansions.
#
# KEN-837 is why this suite exists. `local -A pane_cmd` reached
# `scripts/lib/lane-context.sh` and every gate stayed green, because the shell
# shard runs on ubuntu only (`.github/workflows/skill-tests.yml`). Bash 3.2
# rejects `local -A` as an invalid option, and under that file's `set -euo
# pipefail` it aborts `lanes context` outright rather than losing one lane. A
# reviewer caught it by hand and #1847 removed it; nothing else would have.
#
# Comment lines are not scanned. orch documents this prohibition inside the
# scripts it constrains — `scripts/git-context` and `scripts/lib/lane-context.sh`
# both name the construct they avoid and why — and a lint that reds its own
# contract teaches the next author to delete the explanation instead of the
# construct. Case b.4 pins the skip to comments; b.1-b.3 prove code is still
# caught, so the skip cannot be what makes this suite green.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() {
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
}
fail() {
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n' "$1"
}

PATTERN='mapfile|readarray|declare -A|declare -gA|local -A'
PATTERN="$PATTERN"'|(^|[^$])\{[A-Za-z_][A-Za-z0-9_]*\}[<>]'
PATTERN="$PATTERN"'|\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,,|\^\^)'

# scan_bash4 <dir>
# Emits one `file:line:text` line per Bash 4+ construct found on a non-comment
# line of any regular file under <dir>. Exits 2 when the scan could not run: a
# scan that did not run is not a clean tree, and every caller below tells the
# two apart.
scan_bash4() {
    local dir="$1" list="$TMP_ROOT/scan-list.$$" f hits status
    find "$dir" -type f >"$list" || return 2
    LC_ALL=C sort -o "$list" "$list" || return 2
    while IFS= read -r f; do
        hits=""
        status=0
        # `--` before the operand: a path beginning with `-` parses as options
        # otherwise. grep's status is part of the answer — 0 found, 1 none,
        # anything else a scan that did not run.
        hits="$(grep -nE -- "$PATTERN" "$f")" || status=$?
        if [ "$status" -gt 1 ]; then
            printf 'grep exited %s over %s\n' "$status" "$f" >&2
            return 2
        fi
        [ -n "$hits" ] || continue
        printf '%s\n' "$hits" |
            awk -v f="$f" '!/^[0-9]+:[[:blank:]]*#/ { print f ":" $0 }'
    done <"$list"
}

# count_scripts <dir> — regular files under <dir>, the number this lint read.
count_scripts() {
    find "$1" -type f | wc -l | tr -d ' '
}

# probe_dir <name> <line> — a one-file scripts/ holding <line> as its body.
probe_dir() {
    local d="$TMP_ROOT/probe-$1"
    mkdir -p "$d"
    {
        printf '#!/usr/bin/env bash\n'
        printf '%s\n' "$2"
    } >"$d/probe"
    printf '%s' "$d"
}

# a.1 — the shipped scripts are clean, which is the assertion this file exists
# to make.
violations=""
scan_status=0
violations="$(scan_bash4 "$SCRIPTS_DIR")" || scan_status=$?
if [ "$scan_status" -ne 0 ]; then
    fail "the portability scan over $SCRIPTS_DIR could not run (exit $scan_status)"
elif [ -n "$violations" ]; then
    fail "Bash 4+ constructs in orch scripts (they must run under Bash 3.2):"
    printf '%s\n' "$violations" >&2
else
    pass "no Bash 4+ construct in any shipped orch script"
fi

# a.2 — an absent forbidden construct means nothing when there was nothing to
# look in: an empty scripts/ scans clean.
shipped="$(count_scripts "$SCRIPTS_DIR")"
if [ "$shipped" -gt 0 ]; then
    pass "the scan read $shipped shipped orch script(s)"
else
    fail "no shipped script found under $SCRIPTS_DIR, so this lint read nothing"
fi

# a.3 — and every one of them parses. A construct this pattern set does not
# name still has to be syntax.
syntax_fail=0
while IFS= read -r f; do
    if ! bash -n -- "$f"; then
        fail "bash -n $f"
        syntax_fail=1
    fi
done < <(find "$SCRIPTS_DIR" -type f | LC_ALL=C sort)
[ "$syntax_fail" -eq 1 ] || pass "every shipped orch script parses under bash -n"

# b.1-b.3 — teeth, one per pattern group, injected as code the way KEN-837's
# `local -A` arrived.
for probe in \
    "associative-array:local -A pane_cmd" \
    "mapfile:mapfile -t lanes < panes.txt" \
    "case-conversion:head_lower=\"\${head,,}\"" \
    "fd-allocation:exec {lock_fd}<\"\$lockfile\""; do
    name="${probe%%:*}"
    line="${probe#*:}"
    probe_status=0
    hits="$(scan_bash4 "$(probe_dir "$name" "$line")")" || probe_status=$?
    if [ "$probe_status" -ne 0 ]; then
        fail "scan could not run over the $name probe (exit $probe_status)"
    elif [ -n "$hits" ]; then
        pass "lint flags an injected $name"
    else
        fail "lint MISSED an injected $name (no teeth)"
    fi
done

# b.4 — and the documented exception is exactly that: the same construct, on a
# comment line, is not a violation.
comment_status=0
hits="$(scan_bash4 "$(probe_dir comment '  # has none and rejects `local -A`, which errexit would abort on')")" || comment_status=$?
if [ "$comment_status" -ne 0 ]; then
    fail "scan could not run over the comment probe (exit $comment_status)"
elif [ -z "$hits" ]; then
    pass "lint ignores a comment naming a forbidden construct"
else
    fail "lint false-flagged a comment naming a forbidden construct"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
