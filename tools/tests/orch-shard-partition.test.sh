#!/usr/bin/env bash
# The orch battery outgrew one CI shard, so `.github/workflows/skill-tests.yml`
# runs it as three, and a shard is nothing but a `run-all.sh` name filter:
# `open-terminal`, `oversee`, and the negation of both. That makes the filters
# load-bearing. A filter that stopped matching would leave its suites in no
# shard at all, and every shard would stay green while the battery proved less
# than it claims — the silent loss this file exists to catch.
#
# Two surfaces:
#   1. the filter — a bare argument selects, `!name` rejects, several
#      arguments are a union, an empty one refuses, and a filter that matches
#      no suite exits non-zero instead of reporting an empty pass
#   2. the partition — the filters the workflow passes, read out of the
#      workflow rather than restated here, leave every suite in exactly one
#      shard. The must-fail arms drop a shard and repeat a shard, the two ways
#      that guarantee breaks.
#
# The roster is real and the suites are not: every run below happens in a
# sandbox holding a copy of run-all.sh and one empty file per suite name, so
# the real filter logic runs over the real names without running the battery.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
TEST_DIR="$ROOT/skills/orch/tests"
WORKFLOW="$ROOT/.github/workflows/skill-tests.yml"

mkdir -p "$ROOT/tmp"
TMP="$(mktemp -d "$ROOT/tmp/orch-shard-partition.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { # check <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

# --- The sandbox: the real roster, none of the real work --------------------
SANDBOX="$TMP/battery"
mkdir -p "$SANDBOX/lib"
cp "$TEST_DIR/run-all.sh" "$SANDBOX/run-all.sh"
printf '#!/usr/bin/env bash\n: # the sandbox clears nothing; its suites are empty\n' \
  > "$SANDBOX/lib/git-env.sh"
roster=""
for f in "$TEST_DIR"/*.sh; do
  base="$(basename "$f" .sh)"
  [[ "$base" == "run-all" ]] && continue
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/$base.sh"
  roster="$roster$base
"
done
roster="$(printf '%s' "$roster" | sort)"

selected() { # selected <filter>... ; the suite names that ran, sorted
  bash "$SANDBOX/run-all.sh" "$@" 2>/dev/null |
    sed -n 's/^──── \(.*\) ────$/\1/p' | sort
}
status_of() { # status_of <filter>... ; the exit status, output discarded
  local rc=0
  bash "$SANDBOX/run-all.sh" "$@" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

# --- 1. The filter ----------------------------------------------------------
check "no filter runs the whole battery" "$roster" "$(selected)"
check "a bare argument selects by substring" \
  "$(printf '%s\n' "$roster" | grep '^oversee')" "$(selected oversee)"
check "two arguments are a union, not an intersection" \
  "$(printf '%s\n' "$roster" | grep -E '^(oversee|open-terminal)')" \
  "$(selected oversee open-terminal)"
check "an argument written !name rejects what it matches" \
  "$(printf '%s\n' "$roster" | grep -v '^oversee')" "$(selected '!oversee')"
check "a rejector overrides a selector that also matches" \
  "$(printf '%s\n' "$roster" | grep '^open-terminal')" \
  "$(selected open-terminal oversee '!oversee')"
check "an empty argument refuses instead of running everything" \
  "1" "$(status_of '')"
check "a filter matching no suite exits non-zero" \
  "1" "$(status_of no-suite-carries-this-name)"

# --- 2. The partition the workflow ships ------------------------------------
# Each shard's arguments are read from the workflow, so a shard whose filter
# is edited there is judged here by what that filter now selects.
#
# One line per invocation, each opened by a marker: a shard that passes no
# filter at all is an empty argument string, and without the marker that line
# would vanish into the surrounding newlines and read as no shard.
shard_filters() { # shard_filters <workflow> ; `|<argument string>` per shard
  sed -n 's%^ *run: bash skills/orch/tests/run-all\.sh *%|%p' "$1"
}
union_of() { # union_of <argument string>... ; names selected, duplicates kept
  local args
  for args in "$@"; do
    set -f
    # shellcheck disable=SC2086 # an argument string is a word list by design
    set -- $(printf '%s' "$args" | tr -d "'")
    set +f
    selected "$@"
  done
}
missing_from() { # missing_from <argument string>... ; suites no shard runs
  comm -23 <(printf '%s\n' "$roster") <(union_of "$@" | sort -u)
}
shared_by() { # shared_by <argument string>... ; suites more than one runs
  union_of "$@" | sort | uniq -d
}

filters="$(shard_filters "$WORKFLOW")"
if [[ -z "$filters" ]]; then
  printf '  FAIL  no step in %s runs run-all.sh, so there is no partition to judge\n' \
    "$WORKFLOW"
  printf 'pass: %d   fail: %d\n' "$PASS" "$((FAIL + 1))"
  exit 1
fi
shard_args=()
while IFS= read -r line; do
  shard_args+=("${line#|}")
done <<< "$filters"
# A single invocation is a battery that is no longer split, and the arms below
# have no second shard to drop or repeat, so this refuses rather than reading
# an absent element.
if [[ "${#shard_args[@]}" -lt 2 ]]; then
  printf '  FAIL  %s runs run-all.sh once; the battery is back to a single shard\n' \
    "$WORKFLOW"
  printf 'pass: %d   fail: %d\n' "$PASS" "$((FAIL + 1))"
  exit 1
fi
ok "the workflow runs the battery as ${#shard_args[@]} shards"
check "every suite is claimed by one of the workflow's orch shards" \
  "" "$(missing_from "${shard_args[@]}")"
check "no suite is claimed by two of them" "" "$(shared_by "${shard_args[@]}")"

# --- 2b. Must-fail: the two ways the partition breaks -----------------------
# Dropping a shard leaves the suites only it runs in nothing; repeating one
# runs its suites twice. A check that stays clean under either mutation is
# reporting nothing.
left_behind="$(missing_from "${shard_args[1]}")"
if [[ -n "$left_behind" ]]; then
  ok "must-fail: with one shard's filter alone, the unclaimed suites are named"
else
  bad "must-fail: one shard's filter alone claimed the whole battery, so the coverage check proves nothing"
fi
twice="$(shared_by "${shard_args[@]}" "${shard_args[0]}")"
if [[ -n "$twice" ]]; then
  ok "must-fail: with a shard repeated, the twice-run suites are named"
else
  bad "must-fail: a repeated shard produced no duplicate, so the overlap check proves nothing"
fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
