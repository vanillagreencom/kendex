#!/usr/bin/env bash
# The orch battery outgrew one CI shard, so `.github/workflows/skill-tests.yml`
# runs it as platform partitions, and each shard uses `run-all.sh` filters:
# `open-terminal`, `oversee` in two halves, a third set of name fragments, and
# the negation of all three. That makes the filters load-bearing. A filter that stopped
# matching would leave its suites in no shard at all, and every shard would
# stay green while the battery proved less than it claims — the silent loss
# this file exists to catch.
#
# The same silent loss reaches the rest of the workflow, where a shard is a
# roster of suite FILES rather than a name filter, and where a step may now
# claim individual paths inside a package another step globs. Those steps carry
# fallbacks that read this workflow to decide whether another step already
# claims a suite, so the workflow's own text is load-bearing twice over.
#
# It reaches the cargo lanes too. The macOS kendex-cli lane runs as legs over
# `--test` targets, and the crate guard inside that job spells the workspace
# MEMBERS and covers no list of targets, so a test file added under
# crates/cli/tests and named by no leg would compile under `--no-run` and run
# nowhere while both required cargo contexts stayed green.
#
# Six surfaces:
#   1. the filter — a bare argument selects, `!name` rejects, several
#      arguments are a union, an empty one refuses, and a filter that matches
#      no suite exits non-zero instead of reporting an empty pass
#   2. the orch partition — the filters the workflow passes, read out of the
#      workflow rather than restated here, leave every suite in exactly one
#      shard. The must-fail arms drop a shard and repeat a shard, the two ways
#      that guarantee breaks.
#   3. the shell-shard partition — every file under skills/*/tests/*.sh,
#      tools/tests/*.test.sh and hooks/tests/*.sh is claimed by exactly one
#      shard, or by one job's one-line `run:` steps naming it by path. The
#      must-fail arms drop a roster, repeat a roster, leave a moved path in a
#      comment where only prose can see it, delete the step that globs a
#      package, and delete a job's direct runs.
#   4. the citations — a shard a tracked file names in backticks is one the
#      matrix declares, so a rename cannot leave prose pointing at a lane no
#      leg runs.
#   4b. the selection — for each suite a single-shard step runs, a diff to
#      that suite alone selects that shard through tools/ci-job-set, and every
#      shard the matrix declares runs some suite. The must-fail arm sends one
#      package to another shard.
#   4d. the per-OS partition: every suite stays selected exactly once on each
#      original runner, including linear's shell-version-dependent roster.
#      The omission and duplication controls run on each runner's claims.
#   4c. the macOS exclusions — tools/ci-job-set's Linux-only shard list
#      matches the main-push macOS matrix's exclusions, and the merge
#      queue's macOS shards, the queue job's fallback and ci-job-set's
#      QUEUE_MACOS_SHARDS alike, name none of them. The must-fail arms drop
#      one exclude row, plant a Linux-only queue shard and drop one from
#      QUEUE_MACOS_SHARDS.
#   5. the cargo legs' partition — the macOS kendex-cli lane splits by
#      target and integration test name. The legs are the combinations the
#      matrix expands rather than its raw list. Each target other than the
#      shared integration harness is claimed once. The compiled harness's
#      --list runs through the workflow's own test step and filters, so each
#      integration test is claimed once, and exactly one leg asks
#      for the crate's doc tests, which no `--test` roster can account for.
#      Two contracts ride beside that partition: the bounded leg selects the
#      library and binary unit tests, and the leg the seam exists for claims
#      its one expensive target and nothing else. The must-fail arms empty a
#      leg's roster, repeat a target across two legs, drop the `--doc` and
#      the `--lib --bins` requests, merge the expensive target back into the
#      bounded leg, and delete each of the two workflow shapes read here.
#
# The shell roster is real and the suites are not: every shell run happens in a
# sandbox holding a copy of run-all.sh and one empty file per suite name, or a
# copy of the workflow and a `bash` that does nothing, so the real filter and
# roster logic runs over the real names without running the battery. Cargo's
# integration harness is compiled and listed, but its tests do not run.
set -euo pipefail

# CI separates shell checks from Cargo name checks so the latter reuse the
# macOS rest leg's compiled harness. Local validation runs both by default.
partition_mode() {
  case "$#:${1-}" in
    0:) printf 'combined' ;;
    1:--shell-only) printf 'shell' ;;
    1:--cargo-only) printf 'cargo' ;;
    *) return 2 ;;
  esac
}
mode="$(partition_mode "$@")" || {
  printf 'orch-shard-partition: argument=%s\n' "$*" >&2
  exit 2
}
PARTITION_SUITE=tools/tests/orch-shard-partition.test.sh

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which would resolve ROOT to the hook's
# repository instead of this one.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

ROOT="$(git rev-parse --show-toplevel)"
TEST_DIR="$ROOT/skills/orch/tests"
WORKFLOW="$ROOT/.github/workflows/skill-tests.yml"

mkdir -p "$ROOT/tmp"
TMP="$(mktemp -d "$ROOT/tmp/orch-shard-partition.XXXXXX")" || { echo "orch-shard-partition: scratch=mktemp-failed" >&2; exit 1; }
[[ -d "$TMP" && ! -L "$TMP" ]] || { echo "orch-shard-partition: scratch=not-a-directory value=[$TMP]" >&2; exit 1; }
TMP="$(cd -- "$TMP" && pwd -P)" || { echo "orch-shard-partition: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { # check <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

# One record per step carrying a `run: |` block: the step's `if:` text on the
# `@@` line, its dedented body on the `>` lines. Every body line is prefixed,
# so a body opening with `@` or `>` is not read as a boundary. Indent work is
# substr and not a regex interval — the macOS leg's awk is not GNU's.
BLOCK_AWK="$TMP/run-blocks.awk"
cat > "$BLOCK_AWK" <<'AWK'
substr($0, 1, 8)  == "      - "       { inrun = 0; cond = "" }
substr($0, 1, 12) == "        if: "   { cond = substr($0, 13); next }
substr($0, 1, 14) == "        run: |" { inrun = 1; printf "@@%s\n", cond; next }
inrun == 1 {
  if (substr($0, 1, 10) == "          ") { printf ">%s\n", substr($0, 11); next }
  if ($0 ~ /^[ 	]*$/) { print ">"; next }
  inrun = 0
}
AWK

split_run_blocks() { # split_run_blocks <workflow> <dir> ; <dir>/N.sh and its `if:` text in <dir>/N.cond per block
  local wf="$1" dir="$2" n=0 line
  rm -rf -- "${dir:?}"
  mkdir -p "$dir"
  while IFS= read -r line; do
    case "$line" in
      '@@'*) n=$((n + 1)); : > "$dir/$n.sh"; printf '%s\n' "${line#@@}" > "$dir/$n.cond" ;;
      *)
        if [[ "$n" -gt 0 ]]; then printf '%s\n' "${line#>}" >> "$dir/$n.sh"; fi ;;
    esac
  done < <(awk -f "$BLOCK_AWK" "$wf")
}

# One record per one-line `run:` step: its job, its `if:` text, its working
# directory and its command, parted on the unit separator, which no step text
# holds: a tab IFS would fold an empty field away. A job opens at the
# two-space key under `jobs:`.
one_line_steps() { # one_line_steps <workflow> ; `job\037if\037wd\037run` per step
  awk '
    function flush() { if (wd != "" || run != "") printf "%s\037%s\037%s\037%s\n", job, cond, wd, run; cond = wd = run = "" }
    substr($0, 1, 2) == "  " && substr($0, 3, 1) != " " && substr($0, 3, 1) != "#" && $0 ~ /:$/ { flush(); job = $0; sub(/^ */, "", job); sub(/:$/, "", job) }
    substr($0, 1, 8) == "      - " { flush() }
    substr($0, 1, 12) == "        if: " { cond = substr($0, 13) }
    substr($0, 1, 27) == "        working-directory: " { wd = substr($0, 28) }
    substr($0, 1, 13) == "        run: " && substr($0, 14, 1) != "|" && substr($0, 14, 1) != ">" { run = substr($0, 14) }
    END { flush() }
  ' "$1"
}

partition_cargo_steps() { # <workflow> ; mode, compile order and condition of direct partition checks
  local job cond wd run compiled=false
  one_line_steps "$1" | while IFS=$'\037' read -r job cond wd run; do
    [[ "$job" == cargo-macos ]] || continue
    case "$run" in
      'cargo test '*--no-run*) compiled=true ;;
      "bash $PARTITION_SUITE"*)
        printf '%s:%s:%s:%s\n' "${run#"bash $PARTITION_SUITE"}" "$compiled" "$wd" "$cond" ;;
    esac
  done
}

if [[ "$mode" != cargo ]]; then

# --- The sandbox: the real roster, none of the real work --------------------
SANDBOX="$TMP/orch/tests"
mkdir -p "$SANDBOX/lib" "$TMP/orch/scripts/lib" "$TMP/github/scripts/lib"
cp "$TEST_DIR/run-all.sh" "$SANDBOX/run-all.sh"
cp "$TEST_DIR/../scripts/lib/lane-state.sh" "$TMP/orch/scripts/lib/lane-state.sh"
cp "$ROOT/skills/github/scripts/lib/group-leader.sh" "$TMP/github/scripts/lib/group-leader.sh"
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
  RUNNER_OS="${PARTITION_RUNNER_OS:-Linux}" bash "$SANDBOX/run-all.sh" "$@" 2>/dev/null |
    sed -n 's/^──── \(.*\) ────$/\1/p' | sort
}
status_of() { # status_of <filter>... ; the exit status, output discarded
  local rc=0
  RUNNER_OS="${PARTITION_RUNNER_OS:-Linux}" bash "$SANDBOX/run-all.sh" "$@" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

# --- 1. The filter ----------------------------------------------------------
check "no filter runs the whole battery" "$roster" "$(selected)"
# run-all.sh matches a filter anywhere in a suite's name, so every expectation
# here is a substring match: a prefix match drops a suite that carries the
# filter mid-name.
check "a bare argument selects by substring" \
  "$(printf '%s\n' "$roster" | grep -F 'oversee')" "$(selected oversee)"
check "two arguments are a union, not an intersection" \
  "$(printf '%s\n' "$roster" | grep -F -e 'oversee' -e 'open-terminal')" \
  "$(selected oversee open-terminal)"
check "an argument written !name rejects what it matches" \
  "$(printf '%s\n' "$roster" | grep -vF 'oversee')" "$(selected '!oversee')"
check "a rejector overrides a selector that also matches" \
  "$(printf '%s\n' "$roster" | grep -F 'open-terminal' | grep -vF 'oversee')" \
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
excluded_shards() { # WORKFLOW OS ; shards excluded from that runner's roster
  awk -v os_want="$2" '
    function flush() { if (os == os_want && shard != "") print shard; os = ""; shard = "" }
    /^  [A-Za-z0-9_-]+:/ { job = $1 }
    !((os_want == "macos-latest" && job == "skill-suites-macos:") ||
      (os_want == "ubuntu-latest" && job == "skill-suites-shard:")) { next }
    NF == 0 || $1 == "#" { next }
    { n = 0; while (substr($0, n + 1, 1) == " ") n++ }
    inx == 1 && n < 10 { flush(); inx = 0 }
    inx == 0 && n == 8 && $1 == "exclude:" { inx = 1; next }
    inx == 0 { next }
    $1 == "-" { flush(); key = $2; val = $3 }
    $1 != "-" { key = $1; val = $2 }
    key == "os:" { os = val }
    key == "shard:" { shard = val }
    END { if (inx == 1) flush() }
  ' "$1" | sort -u
}
shard_filters() { # WORKFLOW ; `|<argument string>` per shard on this platform
  local wf="$1" os=ubuntu-latest excluded job cond wd run shard
  [[ "${PARTITION_RUNNER_OS:-Linux}" != macOS ]] || os=macos-latest
  excluded="$(excluded_shards "$wf" "$os")"
  one_line_steps "$wf" | while IFS=$'\037' read -r job cond wd run; do
    [[ "$run" == 'bash skills/orch/tests/run-all.sh'* ]] || continue
    shard="$(one_shard "$cond")"
    grep -qxF "$shard" <<< "$excluded" && continue
    printf '|%s\n' "${run#bash skills/orch/tests/run-all.sh}"
  done
}
# What an argument string selects depends on that string alone, since the
# sandbox battery never changes, so each string's run is made once and kept
# in UNION_RUNS: a file per string, named for its checksum, holding the
# string on its first line, so two strings sharing a checksum are told apart.
UNION_RUNS="$TMP/union-runs"
mkdir -p "$UNION_RUNS"
union_of() { # union_of <argument string>... ; names selected, duplicates kept
  local args kept
  for args in "$@"; do
    kept="$UNION_RUNS/${PARTITION_RUNNER_OS:-Linux}-$(printf '%s' "$args" | cksum | tr ' ' '-')"
    if [[ ! -f "$kept" || "$(head -n 1 "$kept")" != "|$args" ]]; then
      (
        set -f
        # shellcheck disable=SC2086 # an argument string is a word list by design
        set -- $(printf '%s' "$args" | tr -d "'")
        printf '|%s\n' "$args"
        selected "$@"
      ) >"$kept.tmp"
      mv -- "$kept.tmp" "$kept"
    fi
    sed 1d "$kept"
  done
}
missing_from() { # missing_from <argument string>... ; suites no shard runs
  comm -23 <(printf '%s\n' "$roster") <(union_of "$@" | sort -u)
}
shared_by() { # shared_by <argument string>... ; suites more than one runs
  union_of "$@" | sort | uniq -d
}

one_shard() { # if text ; the shard it names when it names exactly one
  local names
  names="$(grep -oE "matrix\.shard == '[^']+'" <<< "$1" | cut -d"'" -f2)" || names=""
  [[ -n "$names" && "$names" != *$'\n'* ]] && printf '%s' "$names"
  return 0
}

for PARTITION_RUNNER_OS in Linux macOS; do
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
ok "the workflow runs the $PARTITION_RUNNER_OS battery as ${#shard_args[@]} shards"
check "every suite is claimed by one of the workflow's orch shards on $PARTITION_RUNNER_OS" \
  "" "$(missing_from "${shard_args[@]}")"
check "no suite is claimed by two of them on $PARTITION_RUNNER_OS" "" "$(shared_by "${shard_args[@]}")"

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

done
PARTITION_RUNNER_OS=Linux

# A new oversee suite belongs to the complement on both platforms, even when its
# name extends one of the moved suites. The workflow produces both profiles.
printf '#!/usr/bin/env bash\n' > "$SANDBOX/oversee_watch_terminal_future.sh"
for PARTITION_RUNNER_OS in Linux macOS; do
for profile in orch-oversee orch-oversee-watch; do
  kept="$(selected --shard "$profile")"
  if [[ "$profile" == orch-oversee ]]; then
    grep -qx oversee_watch_terminal_future <<< "$kept" && ok "new oversee suite enters the $PARTITION_RUNNER_OS complement" || bad "new oversee suite lost from $PARTITION_RUNNER_OS complement"
    ! grep -qx oversee_watch_lifecycle <<< "$kept" && ok "lifecycle leaves the $PARTITION_RUNNER_OS complement" || bad "lifecycle remains in $PARTITION_RUNNER_OS complement"
  else
    grep -qx oversee_watch_lifecycle <<< "$kept" && ok "lifecycle runs in the $PARTITION_RUNNER_OS watch leg" || bad "lifecycle lost from $PARTITION_RUNNER_OS watch leg"
    ! grep -qx oversee_watch_terminal_future <<< "$kept" && ok "$PARTITION_RUNNER_OS watch leg owns only the moved whole names" || bad "$PARTITION_RUNNER_OS watch leg claims a new name extension"
  fi
done
done
rm -- "$SANDBOX/oversee_watch_terminal_future.sh"
# The lifecycle suite must reach the moved leg. Remove its selector from a
# disposable runner copy while retaining its suite and the rest of the rule.
cp "$SANDBOX/run-all.sh" "$TMP/runner-original"
sed 's/ =oversee_watch_lifecycle / /' "$TMP/runner-original" > "$SANDBOX/run-all.sh"
cmp -s "$TMP/runner-original" "$SANDBOX/run-all.sh" && bad "lifecycle control changed no selector"
for PARTITION_RUNNER_OS in Linux macOS; do
  kept="$(selected --shard orch-oversee-watch)"
  ! grep -qx oversee_watch_lifecycle <<< "$kept" && ok "must-fail: missing lifecycle selector fails its $PARTITION_RUNNER_OS moved-leg contract" || bad "$PARTITION_RUNNER_OS lifecycle omission control retained the suite"
done
cp "$TMP/runner-original" "$SANDBOX/run-all.sh"
PARTITION_RUNNER_OS=Windows
for profile in orch-oversee orch-oversee-watch; do
  check "$profile refuses an unsupported platform" "1" "$(status_of --shard "$profile")"
done
# GitHub's Windows runner is outside the orch shard's supported platforms.
# Accept it in a disposable runner to prove that the refusal checks fail.
sed 's/Linux|macOS)/Linux|macOS|Windows)/' "$TMP/runner-original" > "$SANDBOX/run-all.sh"
cmp -s "$TMP/runner-original" "$SANDBOX/run-all.sh" && bad "platform control changed no refusal"
for profile in orch-oversee orch-oversee-watch; do
  check "must-fail: $profile accepts Windows after its platform refusal is removed" \
    "0" "$(status_of --shard "$profile")"
done
cp "$TMP/runner-original" "$SANDBOX/run-all.sh"
PARTITION_RUNNER_OS=Linux

# --- 3. The shell shards' partition over every suite FILE -------------------
# Section 2 judges one seam, the orch battery's name filters. The rest of the
# workflow is a second seam and a coarser one: steps discover suite rosters
# of suite files, and since two of them name individual paths inside a package
# another one globs, the file-level partition can no longer be read off the
# globs. Three of the eight, the commit-guards, tools and rest steps, also
# carry a fallback: each runs a suite another step claims only while that
# step's path or glob is missing from the workflow's run text. A fallback
# satisfied by a path written in a COMMENT would let two shards both skip the
# same suite and both exit 0. The aggregator asserts job success, never
# suite count, so nothing downstream sees the loss.
#
# Rosters come from each step's run block in a sandbox whose workflow is the
# copy under test and whose trees are this checkout. A `bash` shim leaves
# serial suite calls empty and runs pooled calls over empty suite copies.
# Both report `=== <path>` from the real globs, skip arms and name filters.
#
# The file keeps its name: the orch filters above are still the seam most
# likely to be edited, and this section is the same invariant one level out.

# The sandbox: the workflow under test at the path a step's `$wf` spells, and
# the real trees its globs expand over.
PART="$TMP/partition"
mkdir -p "$PART/.github/workflows"
ln -s "$ROOT/skills" "$PART/skills"
ln -s "$ROOT/tools"  "$PART/tools"
ln -s "$ROOT/hooks"  "$PART/hooks"
ln -s "$ROOT/refresh" "$PART/refresh"
# Pooled calls use the real runners over empty copies of the suite files.
# This preserves their discovery and filters without starting the batteries.
POOL="$TMP/pool"
mkdir -p "$POOL/skills/orch/tests/lib" "$POOL/skills/orch/scripts/lib" "$POOL/tools/tests" "$TMP/pool-claims"
mkdir -p "$POOL/skills/github/scripts/lib"
cp "$TEST_DIR/run-all.sh" "$POOL/skills/orch/tests/run-all.sh"
cp "$TEST_DIR/lib/git-env.sh" "$POOL/skills/orch/tests/lib/git-env.sh"
cp "$TEST_DIR/../scripts/lib/lane-state.sh" "$POOL/skills/orch/scripts/lib/lane-state.sh"
cp "$ROOT/skills/github/scripts/lib/group-leader.sh" "$POOL/skills/github/scripts/lib/group-leader.sh"
cp "$ROOT/tools/tests/run-all.sh" "$POOL/tools/tests/run-all.sh"
for f in "$ROOT"/skills/*/tests/*.sh "$ROOT"/tools/tests/*.test.sh; do
  [[ "${f##*/}" != run-all.sh ]] || continue
  path="${f#"$ROOT"/}"
  mkdir -p "$POOL/${path%/*}"
  printf '#!/usr/bin/env bash\n' > "$POOL/$path"
done
# `bash "$t"` in a roster loop prints nothing. A pooled invocation reports
# its selected files with the same marker the loop uses. Cached invocations
# have immutable empty batteries, like section 2's UNION_RUNS.
SHIM="$TMP/shim"
mkdir -p "$SHIM"
printf '#!%s\n' "$BASH" > "$SHIM/bash"
cat >> "$SHIM/bash" <<'SH'
set -euo pipefail
case "$1:${2-}" in
  tools/tests/run-all.sh:*) battery=tools/tests ;;
  skills/orch/tests/run-all.sh:--battery) battery="$3" ;;
  *) battery='' ;;
esac
if [[ -n "$battery" ]]; then
  key="$(printf '%s\n' "$@" | cksum | tr ' ' '-')"
  cache="$PARTITION_POOL_CLAIMS/$key"
  if [[ ! -f "$cache" ]]; then
    # No job deadline or inherited pool bound applies to empty fixture suites.
    (cd "$PARTITION_POOL" && env -u RUN_ALL_DEADLINE_EPOCH -u RUN_ALL_SUITE_SECS \
      PATH="$PARTITION_HOST_PATH" "$BASH" "$@") >"$cache.out" || exit 1
    sed -n "s%^──── \(.*\) ────\$%=== $battery/\1.sh%p" "$cache.out" > "$cache"
  fi
  cat "$cache"
  exit 0
fi
if [ "$1" = tools/tests/orch-shard-partition.test.sh ]; then
  shift
  printf 'partition-arguments: %s\n' "$*"
fi
exit 0
SH
chmod +x "$SHIM/bash"
export PARTITION_POOL="$POOL" PARTITION_POOL_CLAIMS="$TMP/pool-claims" PARTITION_HOST_PATH="$PATH"

# Serial blocks carry the path marker. Pooled blocks invoke a battery runner.
# Orch's name-filter calls remain accounted for by section 2.
ROSTER_MARK='=== $t'
roster_block() { # FILE ; a serial roster or a pooled battery invocation
  grep -qF -e "$ROSTER_MARK" -e 'bash tools/tests/run-all.sh' \
    -e 'bash skills/orch/tests/run-all.sh --battery' "$1"
}

# A job outside the shell matrix may run a suite by path. Each job claims
# a path once, and only a path in the suite universe counts.
run_paths() { # <run command> ; existing paths whose invocation owns shell work
  local word invocation_mode
  set -f
  # Workflow one-line commands name unquoted paths and mode switches.
  # shellcheck disable=SC2086
  set -- $1
  set +f
  while [[ "$#" -gt 0 ]]; do
    word="$1"
    shift
    [[ "$word" == */* && -f "$ROOT/$word" ]] || continue
    if [[ "$word" == "$PARTITION_SUITE" ]]; then
      invocation_mode="$(partition_mode "$@")" || return
      [[ "$invocation_mode" != cargo ]] || continue
    fi
    printf '%s\n' "$word"
  done
}

direct_claims() { # direct_claims <workflow> ; one path per job that runs its shell work
  local job cond wd run word
  one_line_steps "$1" | while IFS=$'\037' read -r job cond wd run; do
    [[ -z "$wd" ]] || continue
    while IFS= read -r word; do
      if grep -qxF -- "$word" "$UNIV"; then printf '%s\t%s\n' "$job" "$word"; fi
    done < <(run_paths "$run")
  done | sort -u | cut -f2
}

claims_of() { # claims_of <workflow> ; every path its roster steps claim
  local wf="$1" dir="$TMP/blocks" f line
  cp "$wf" "$PART/.github/workflows/skill-tests.yml"
  split_run_blocks "$wf" "$dir"
  for f in "$dir"/*.sh; do
    roster_block "$f" || continue
    ( cd "$PART" && PATH="$SHIM:$PATH" "$BASH" "$f" ) 2>/dev/null |
      sed -n 's/^=== //p'
  done
  # The orch steps pass name filters to run-all.sh and print no path of their
  # own, so their claims come through section 2's sandbox: the same filters,
  # read out of the same copy, mapped back to the files those names are.
  # The emptiness test is on the string, not on the array: under `set -u` a
  # Bash 3.2 ${#array[@]} over an array with no element is an unbound
  # variable, and the macOS leg runs that shell.
  local ofilters
  ofilters="$(shard_filters "$wf")"
  if [[ -n "$ofilters" ]]; then
    local oargs=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && oargs+=("${line#|}")
    done <<< "$ofilters"
    union_of "${oargs[@]}" | sed "s%^%$ORCH_TESTS_DIR/%; s%\$%.sh%"
  fi
  direct_claims "$wf"
}

# `linear` is out of the file-level accounting on purpose: its step runs the
# whole package under Bash 4 and the one runtime-contract suite under Bash 3,
# so its roster depends on the leg. Its package is judged by the glob claim
# below instead.
LINEAR_PREFIX='skills/linear/tests/'

# Read once from the workflow: the runner the orch steps invoke by path. Its
# directory is where their filters' names resolve to files, and the file
# itself is the one entry in neither shard's roster, being the battery's
# driver rather than a suite.
runner="$(sed -n 's%^ *run: bash \([^ ]*/run-all\.sh\).*%\1%p' "$WORKFLOW" |
  sort -u)"
case "$runner" in
  '')
    bad "no step invokes a run-all.sh by path, so no orch roster can be resolved"
    runner="no/such/runner.sh" ;;
  *"
"*)
    bad "more than one run-all.sh is invoked by path, so the orch roster has no single home: $runner" ;;
esac
ORCH_TESTS_DIR="$(dirname "$runner")"

claims_file() { # claims_file <workflow> <out> ; the sorted claim list
  claims_of "$1" | grep -v "^$LINEAR_PREFIX" | sort > "$2" || true
}

shell_partition_args() { # <workflow> ; actual arguments from the shell roster invocation
  local wf="$1" dir="$TMP/partition-mode-blocks" f
  cp "$wf" "$PART/.github/workflows/skill-tests.yml"
  split_run_blocks "$wf" "$dir"
  for f in "$dir"/*.sh; do
    grep -qF "$ROSTER_MARK" "$f" || continue
    ( cd "$PART" && PATH="$SHIM:$PATH" "$BASH" "$f" ) 2>/dev/null |
      sed -n 's/^partition-arguments: //p'
  done
}

# The universe: the three globs the roster steps loop over, less the runner
# the orch steps invoke by path. That runner drives the battery and is not a
# suite, the same exclusion section 2's roster makes by name. A file here that
# no roster runs is claimed by a job that runs it by path, or by nothing.
UNIV="$TMP/universe"
(
  cd "$ROOT" || exit 1
  for f in skills/*/tests/*.sh tools/tests/*.test.sh hooks/tests/*.sh refresh/tests/*.test.sh; do
    [[ "$f" == "$runner" ]] && continue
    case "$f" in "$LINEAR_PREFIX"*) continue ;; esac
    printf '%s\n' "$f"
  done
) | sort > "$UNIV"

HEAD_CLAIMS="$TMP/claims-head"
claims_file "$WORKFLOW" "$HEAD_CLAIMS"

check "every suite file is claimed by one of the workflow's shell shards" \
  "" "$(comm -23 "$UNIV" <(sort -u "$HEAD_CLAIMS"))"
check "no suite file is claimed by two of them" "" "$(uniq -d "$HEAD_CLAIMS")"
check "every claim names a file that exists, so no roster carries a phantom" \
  "" "$(comm -13 "$UNIV" <(sort -u "$HEAD_CLAIMS"))"
check "exactly one run block claims the linear package by glob" \
  "1" "$(grep -lF "${LINEAR_PREFIX}*.sh" "$TMP/blocks"/*.sh | wc -l | tr -d ' ')"

check "the shell roster invokes only the shell partition" \
  "--shell-only" "$(shell_partition_args "$WORKFLOW")"
check "a Cargo-only one-line call owns no shell suite" \
  "" "$(direct_claims "$WORKFLOW" | grep -xF "$PARTITION_SUITE" || true)"

# The actual Cargo step is a one-line producer. Replacing only its mode must
# restore shell ownership for a full or shell-only call, including duplicates.
for args in '' --shell-only --cargo-only; do
  mutant="$TMP/wf-partition-direct-${args:-combined}.yml"
  sed "s%run: bash $PARTITION_SUITE --cargo-only%run: bash $PARTITION_SUITE $args%" \
    "$WORKFLOW" > "$mutant"
  claims_file "$mutant" "$TMP/mode-claims"
  expected="$PARTITION_SUITE"
  [[ "$args" != --cargo-only ]] || expected=''
  check "direct mode ${args:-combined} has the required shell ownership" \
    "$expected" "$(uniq -d "$TMP/mode-claims")"
done

wf_no_shell_partition="$TMP/wf-shell-partition-dropped.yml"
sed "s%$PARTITION_SUITE; do%; do%" "$WORKFLOW" > "$wf_no_shell_partition"
claims_file "$wf_no_shell_partition" "$TMP/no-shell-partition-claims"
check "must-fail: a Cargo-only call cannot cover an omitted shell suite" \
  "$PARTITION_SUITE" "$(comm -23 "$UNIV" <(sort -u "$TMP/no-shell-partition-claims"))"

for args in '' --cargo-only; do
  mutant="$TMP/wf-partition-shell-${args:-combined}.yml"
  sed "s/set -- --shell-only/set -- $args/" "$WORKFLOW" > "$mutant"
  if [[ "$(shell_partition_args "$mutant")" != --shell-only ]]; then
    ok "must-fail: shell mode ${args:-combined} violates the actual invocation contract"
  else
    bad "must-fail: shell mode ${args:-combined} is accepted"
  fi
done

# --- 3b. Must-fail: the ways this partition breaks --------------------------
# Each arm mutates a copy of the workflow, and the section above must name the
# damage. An arm that stays clean means the section reports nothing. An arm
# whose needle no longer matches the workflow leaves the copy unchanged and
# judges the workflow itself, so each copy must differ from what it mutates.
edited() { # edited <original> <copy> <arm> ; fails the arm whose edit matched nothing
  if cmp -s -- "$1" "$2"; then
    bad "mutation-unmatched arm=[$3]: the copy equals $(basename -- "$1"), so the arm judges nothing"
  fi
}

# A roster no fallback covers, dropped. No skip list points at the tools/tests
# glob, so the files it alone claims land in no shard at all.
wf_drop="$TMP/wf-roster-dropped.yml"
awk '{
  if (index($0, "bash tools/tests/run-all.sh")) { hits++; next }
  print
}
END { exit hits != 1 }
' "$WORKFLOW" > "$wf_drop"
edited "$WORKFLOW" "$wf_drop" roster-dropped
claims_file "$wf_drop" "$TMP/claims-drop"
if [[ -n "$(comm -23 "$UNIV" <(sort -u "$TMP/claims-drop"))" ]]; then
  ok "must-fail: a dropped roster leaves its files unclaimed, and they are named"
else
  bad "must-fail: dropping a roster left nothing unclaimed, so the coverage check proves nothing"
fi

# The pooled tools step must keep the tail out. Slack must discover its own
# directory. Each damaged copy is judged by the same claims reader above.
wf_tools_tail="$TMP/wf-tools-tail-repeated.yml"
awk '
  /set -- "\$@" "!=\$\{base%\.sh\}"/ {
    print "              [ \"$base\" = harness-smoke.test.sh ] || " $0; hits++; next
  }
  { print }
  END { exit hits != 1 }
' "$WORKFLOW" > "$wf_tools_tail" || bad "tools tail control matched other than once"
edited "$WORKFLOW" "$wf_tools_tail" tools-tail-repeated
claims_file "$wf_tools_tail" "$TMP/claims-tools-tail"
check "must-fail: tools stops rejecting harness-smoke and claims it twice" \
  "tools/tests/harness-smoke.test.sh" "$(uniq -d "$TMP/claims-tools-tail")"

wf_slack_directory="$TMP/wf-slack-wrong-directory.yml"
awk '
  /bash skills\/orch\/tests\/run-all.sh --battery skills\/slack\/tests/ {
    sub(/--battery skills\/slack\/tests/, "--battery skills/slack/tests/wrong"); hits++
  }
  { print }
  END { exit hits != 1 }
' "$WORKFLOW" > "$wf_slack_directory" || bad "Slack directory control matched other than once"
edited "$WORKFLOW" "$wf_slack_directory" slack-wrong-directory
claims_file "$wf_slack_directory" "$TMP/claims-slack-directory"
check "must-fail: Slack's wrong battery leaves its suites claimed by none" \
  "$(grep "^skills/slack/tests/" "$UNIV")" \
  "$(comm -23 "$UNIV" <(sort -u "$TMP/claims-slack-directory"))"

# A roster claimed twice.
wf_twice="$TMP/wf-roster-repeated.yml"
awk '{
  if (index($0, "for t in skills/review-gate/tests/*.test.sh refresh/tests/*.test.sh; do"))
    sub(/; do/, " skills/worktree/tests/*.sh; do")
  print
}' "$WORKFLOW" > "$wf_twice"
edited "$WORKFLOW" "$wf_twice" roster-repeated
claims_file "$wf_twice" "$TMP/claims-twice"
if [[ -n "$(uniq -d "$TMP/claims-twice")" ]]; then
  ok "must-fail: a roster added to a second step is named as claimed twice"
else
  bad "must-fail: a repeated roster produced no duplicate, so the overlap check proves nothing"
fi

# A moved path left only in a comment. The fallback in the step that globs the
# path's package reads run-block text, so it reclaims the suite and the
# partition holds; with that filter removed it reads the comment instead,
# skips the suite, and the suite runs in no shard. Each row is one arm: the
# first check says the fallback fires, the second says this section is what
# catches it when it does not. A row is `path|loop`, the moved path and the
# first line of the loop that spells it, above which the comment goes so the
# loop's continuation lines stay whole.
prose_rows=0
while IFS='|' read -r moved loop; do
  prose_rows=$((prose_rows + 1))
  wf_prose="$TMP/wf-path-in-comment-$prose_rows.yml"
  awk -v moved="$moved" -v loop="$loop" '
    index($0, loop) { print "          # " moved; hits++ }
    (i = index($0, moved " \\")) { $0 = substr($0, 1, i - 1) substr($0, i + length(moved) + 1); cut++ }
    { print }
    END { exit !(hits == 1 && cut == 1) }
  ' "$WORKFLOW" > "$wf_prose" ||
    { bad "the prose arm for $moved found its loop or its path other than once in $WORKFLOW"; continue; }
  claims_file "$wf_prose" "$TMP/claims-prose"
  check "a moved path left only in a comment is reclaimed by its fallback shard: $moved" \
    "" "$(comm -23 "$UNIV" <(sort -u "$TMP/claims-prose"))"

  wf_open="$TMP/wf-path-in-comment-fallback-open-$prose_rows.yml"
  awk '{
    if ($0 ~ /claims="\$\(grep -v/) { print "          claims=\"$(cat \"$wf\")\""; next }
    print
  }' "$wf_prose" > "$wf_open"
  edited "$wf_prose" "$wf_open" "comment-filter-removed $moved"
  claims_file "$wf_open" "$TMP/claims-open"
  if grep -qxF -- "$moved" <<< "$(comm -23 "$UNIV" <(sort -u "$TMP/claims-open"))"; then
    ok "must-fail: with the comment filter removed, the prose-only $moved runs in no shard and is named"
  else
    bad "must-fail: a fallback matching comment text left $moved claimed, so the filter is unproven"
  fi
done <<'ROWS'
skills/commit-guards/tests/install-git-hooks.test.sh|for t in hooks/tests/*.sh
tools/tests/harness-smoke.test.sh|for t in tools/tests/harness-smoke.test.sh
ROWS
[[ "$prose_rows" -eq 2 ]] || bad "the prose arm table read $prose_rows rows, not 2"

# The step that globs a package, deleted. `rest` skips a package only where
# this file still runs it, and the needle it looks for is the owning loop's
# glob, which leaves with that loop; the package's suites come back here
# instead of going nowhere. The two paths `guards-hooks` spells stay, so they
# are claimed twice, which costs time and loses no suite. With the needle
# reverted to the package's DIRECTORY PREFIX the two surviving paths answer
# for the whole package and its other suites run in no shard, which is the
# second half of this arm.
wf_nostep="$TMP/wf-globbing-step-deleted.yml"
awk '
  index($0, "- name: commit-guards suites") { drop = 1; next }
  drop == 1 && substr($0, 1, 8) == "      - " { drop = 0 }
  drop == 1 { next }
  { print }
' "$WORKFLOW" > "$wf_nostep"
edited "$WORKFLOW" "$wf_nostep" globbing-step-deleted
claims_file "$wf_nostep" "$TMP/claims-nostep"
check "with the step that globs a package deleted, no suite of it is unclaimed" \
  "" "$(comm -23 "$UNIV" <(sort -u "$TMP/claims-nostep"))"

wf_prefix="$TMP/wf-prefix-needle.yml"
awk '{ sub(/needle="skills\/\$x\/tests\/\*\.sh"/, "needle=\"skills/$x/tests/\""); print }' \
  "$wf_nostep" > "$wf_prefix"
edited "$wf_nostep" "$wf_prefix" prefix-needle
claims_file "$wf_prefix" "$TMP/claims-prefix"
if [[ -n "$(comm -23 "$UNIV" <(sort -u "$TMP/claims-prefix"))" ]]; then
  ok "must-fail: a directory-prefix needle answers for a deleted step and the package's suites are named unclaimed"
else
  bad "must-fail: a directory-prefix needle lost no suite, so the glob needle is unproven"
fi

# --- 4. Shard names cited in tracked text -----------------------------------
# A shard's name reaches prose: an AGENTS.md sends a contributor to the lane
# that runs a file, and a suite header says which shard keeps the check
# merge-blocking. A rename leaves those citations naming a shard the matrix no
# longer declares, which is how four went stale at once when `guards` became
# three shards.
#
# The form judged is the repository's own, a name in backticks followed by
# `shard`. Bare prose naming a FAMILY is outside it and stays prose: "the orch
# shard filters" means the four orch- shards, and no grammar here separates
# that from a stale singular. The workflow itself is excluded, being where the
# matrix lives and where a retired name is deliberately kept: its own history
# sentences still say what the undivided guards and rest shards once cost.
# The form is tools/ci-job-set's SHARD_CITATION, which also runs this suite
# for a changed file citing one.
CITATION="$(sed -n "s/^SHARD_CITATION='\(.*\)'\$/\1/p" "$ROOT/tools/ci-job-set")"
[[ -n "$CITATION" ]] || bad "no SHARD_CITATION read from tools/ci-job-set, so no citation can be judged"
cited_shards() { # cited_shards ; NUL paths on stdin -> path:line:name per citation
  { xargs -0 grep -HIonE "$CITATION" 2>/dev/null || true; } |
    sed 's/:`\([a-z0-9-]*\)` shards\{0,1\}$/:\1/'
}

# The matrix's shard key expands the list the changes job selects, and the
# whole roster, its literal, where nothing was selected.
declared_shards="$(sed -n "s/^ \{8\}shard: .*'\[\(.*\)\]'.*\$/\1/p" "$WORKFLOW" |
  tr -d ' "' | tr ',' '\n' | sort -u)"
if [[ -z "$declared_shards" ]]; then
  bad "no shard list in $WORKFLOW, so no citation can be judged against it"
fi

stale=""
cites=0
while IFS= read -r hit; do
  [[ -n "$hit" ]] || continue
  cites=$((cites + 1))
  # A here-string and not a pipe: `grep -q` stops at the first match, and a
  # writer it SIGPIPEs returns 141 under pipefail, which here would read as a
  # citation the matrix does not declare.
  if ! grep -qxF "${hit##*:}" <<< "$declared_shards"; then
    stale="$stale$hit
"
  fi
done < <(git -C "$ROOT" ls-files -z -- . \
  ':(exclude).github/workflows/skill-tests.yml' | cited_shards)

check "every shard a tracked file cites in backticks is one the matrix declares" \
  "" "$(printf '%s' "$stale")"
if [[ "$cites" -gt 0 ]]; then
  ok "the citation scan read $cites backticked shard citation(s) in tracked text"
else
  bad "the citation scan read no citation at all, so a stale one would pass unseen"
fi

# Must-fail: the scan reads a name no matrix declares out of prose it is given.
# The name is substituted rather than written out: this file is tracked text
# too, and a citation spelled here would be one the scan reads for real.
fixture="$TMP/citation-fixture.md"
fake=no-such-shard
printf 'the suite runs under the `%s` shard of the workflow\n' "$fake" > "$fixture"
arm="$(printf '%s\0' "$fixture" | cited_shards)"
if [[ "${arm##*:}" == "$fake" ]] &&
   ! grep -qxF "$fake" <<< "$declared_shards"; then
  ok "must-fail: a citation naming no declared shard is read out and judged stale"
else
  bad "must-fail: the scan did not read a fabricated shard name, so a stale citation would pass"
fi

# --- 4b. The shard selection reaches every suite a shard runs -------------
# tools/ci-job-set chooses which shards a diff runs from a package table of
# its own, and the steps above are what run each package's suites. A package
# that table sends to the wrong shard stands down the shard running its suites
# on exactly the diffs that change them, and every leg that does run stays
# green. So each suite a single-shard step runs — a roster path, the orch
# runner, a node step's package, a scan's script — is handed to ci-job-set as
# a one-path `micro` diff, and the step's shard must be in the list that
# comes back. One path per shard and directory stands for the rest of that
# directory, which the table cannot tell apart.
JOB_SET="$ROOT/tools/ci-job-set"

suite_owners() { # <workflow> [files [bash-major]] ; `shard<tab>path`, by directory or every file
  local wf="$1" mode="${2-directories}" major="${3-}" dir="$TMP/owner-blocks" f shard cond wd run word
  local PARTITION_RUNNER_OS=Linux os=ubuntu-latest excluded
  [[ "$major" != 3 ]] || { PARTITION_RUNNER_OS=macOS; os=macos-latest; }
  excluded="$(excluded_shards "$wf" "$os")"
  cp "$wf" "$PART/.github/workflows/skill-tests.yml"
  split_run_blocks "$wf" "$dir"
  {
    for f in "$dir"/*.sh; do
      roster_block "$f" || continue
      shard="$(one_shard "$(cat "${f%.sh}.cond")")"
      [[ -n "$shard" ]] || continue
      # Bash's version array is readonly. This disposable runner copy injects
      # the major version to exercise linear's actual roster branch on Linux.
      sed 's/${BASH_VERSINFO\[0\]}/${PARTITION_BASH_MAJOR}/g' "$f" > "$dir/runner"
      ( cd "$PART" && PARTITION_BASH_MAJOR="${major:-${BASH_VERSINFO[0]}}" PATH="$SHIM:$PATH" "$BASH" "$dir/runner" ) 2>/dev/null |
        sed -n "s%^=== %$shard	%p"
    done
    # One-line steps: the package a node step works in, or the first word of
    # its `run:` that names a file in this tree.
    one_line_steps "$wf" | while IFS=$'\037' read -r _ cond wd run; do
      shard="$(one_shard "$cond")"
      [[ -n "$shard" ]] || continue
      grep -qxF "$shard" <<< "$excluded" && continue
      if [[ "$mode" == files && "$run" == "bash $runner"* ]]; then
        union_of "${run#"bash $runner"}" | sed "s%^%$shard	$ORCH_TESTS_DIR/%; s%\$%.sh%"
        continue
      fi
      if [[ -n "$wd" ]]; then
        printf '%s\t%s/package.json\n' "$shard" "$wd"
        continue
      fi
      while IFS= read -r word; do
        printf '%s\t%s\n' "$shard" "$word"
        break
      done < <(run_paths "$run")
    done
  } | awk -F '\t' -v mode="$mode" 'mode == "files" { print; next } { d = $2; sub(/\/[^\/]*$/, "", d) } !seen[$1 "\t" d]++'
}

unselected_owners() { # unselected_owners <ci-job-set> <owners file> ; `shard<tab>path` the selection misses
  local job_set="$1" shard path out="$TMP/owner-selection"
  while IFS=$'\t' read -r shard path; do
    : > "$out"
    ( cd "$ROOT" && CHANGE_CLASS=micro DOCS_ONLY=false CHANGED_PATHS="$path" EVENT=pull_request \
      GITHUB_OUTPUT="$out" "$job_set" ) 2>/dev/null ||
      { printf '%s\t%s\tci-job-set-failed\n' "$shard" "$path"; continue; }
    grep -qF "\"$shard\"" "$out" || printf '%s\t%s\n' "$shard" "$path"
  done < "$2"
}

OWNERS="$TMP/owners"
{ suite_owners "$WORKFLOW"; suite_owners "$WORKFLOW" directories 3; } | sort -u > "$OWNERS"
owner_shards="$(cut -f1 "$OWNERS" | sort -u)"
check "a suite is read for every shard the matrix declares" "$declared_shards" "$owner_shards"
check "ci-job-set selects the shard running each suite for a diff to that suite" \
  "" "$(unselected_owners "$JOB_SET" "$OWNERS")"

# Must-fail: removing Slack's package row leaves its shard standing down on
# a Slack diff, and the suite its selection misses is named. The edit reaches
# the Slack rows alone, and every other row's selection is the check's above,
# so the control hands the mutant those rows and wants each of them back.
mkdir -p "$TMP/owner-tools"
cp "$ROOT/tools/rust-reads" "$TMP/owner-tools/rust-reads"
cp -R "$ROOT/tools/lib" "$TMP/owner-tools/lib"
awk '$0 ~ /^    skills\/slack\) want_shard slack ;;$/ { n++; next } { print } END { exit n != 1 }' \
  "$JOB_SET" > "$TMP/owner-tools/ci-job-set" ||
  { bad "must-fail: the Slack row is no longer one line in $JOB_SET"; }
chmod +x "$TMP/owner-tools/ci-job-set"
grep "^slack	skills/slack/tests/" "$OWNERS" >"$TMP/owners-slack" ||
  bad "must-fail: no Slack suite is read from the workflow, so the Slack control has no row"
if [[ -s "$TMP/owners-slack" &&
  "$(unselected_owners "$TMP/owner-tools/ci-job-set" "$TMP/owners-slack")" == "$(cat "$TMP/owners-slack")" ]]; then
  ok "must-fail: a table sending Slack elsewhere names the Slack suites"
else
  bad "must-fail: a table sending Slack elsewhere named nothing, so the selection check proves nothing"
fi

# The moved suites need the refresh path to reach the review-gate shard.
awk '$0 ~ /^      refresh\/\*) want_package refresh ;;$/ { n++; next } { print } END { exit n != 1 }' \
  "$JOB_SET" >"$TMP/owner-tools/ci-job-set" || bad "refresh selection control changed nothing"
grep "^review-gate	refresh/tests/" "$OWNERS" >"$TMP/owners-refresh" ||
  bad "refresh selection control has no suite"
if [[ -s "$TMP/owners-refresh" &&
  "$(unselected_owners "$TMP/owner-tools/ci-job-set" "$TMP/owners-refresh")" == "$(cat "$TMP/owners-refresh")" ]]; then
  ok "must-fail: removing refresh selection names every omitted refresh suite"
else bad "refresh shard selection control"; fi

# --- 4c. The main-push macOS matrix's exclusions --------------------------
# The selector uses these exclusions for its macOS runner arithmetic.
# .github/workflows/skill-tests.yml owns execution policy: its main-push
# macOS job uses the full fallback roster and applies these exclusions.

# The shards the main-push macOS matrix excludes, read as
# YAML sequence items the way cargo_excluded_legs reads them.
macos_excluded_shards() { # macos_excluded_shards <workflow>
  excluded_shards "$1" macos-latest
}
linux_only_shards() { # linux_only_shards <ci-job-set>
  sed -n 's/^LINUX_ONLY_SHARDS="\(.*\)"$/\1/p' "$1" | tr ' ' '\n' | grep . | sort -u
}
excluded="$(macos_excluded_shards "$WORKFLOW")"
grep -qx node <<< "$excluded" ||
  bad "no node exclude read from $WORKFLOW, so the exclude reader is broken"
check "ci-job-set's Linux-only shards are the ones the matrix excludes on macOS" \
  "$excluded" "$(linux_only_shards "$JOB_SET")"
awk '$0 == "            shard: pi-claude-bridge" && prev == "          - os: macos-latest" { n++; skip = 1 }
     { if (!skip && NR > 1) print prev; skip = 0; prev = $0 }
     END { print prev; exit n != 1 }' "$WORKFLOW" > "$TMP/one-exclude.yml" ||
  bad "must-fail: the pi-claude-bridge exclude is no longer one row in $WORKFLOW"
if [[ "$(macos_excluded_shards "$TMP/one-exclude.yml")" != "$(linux_only_shards "$JOB_SET")" ]]; then
  ok "must-fail: a matrix dropping one macOS exclude disagrees with ci-job-set"
else
  bad "must-fail: a matrix dropping one macOS exclude disagrees with ci-job-set"
fi

# The merge queue's macOS legs: the queue job's fallback list, which runs
# where nothing classified, names ci-job-set's QUEUE_MACOS_SHARDS, the list
# its selection draws from, and none of them is a shard the macOS roster
# excludes as Linux-only.
queue_fallback_shards() { # queue_fallback_shards <workflow>
  awk '/^  [A-Za-z0-9_-]+:/ { job = $1 }
       job == "skill-suites-macos-queue:" && /^        shard: / { print }' "$1" |
    sed -n "s/.*'\(\[[^]]*\]\)'.*/\1/p" | tr -d '[]" ' | tr ',' '\n' | grep . | sort -u
}
queue_job_set_shards() { # queue_job_set_shards <ci-job-set>
  sed -n 's/^QUEUE_MACOS_SHARDS="\(.*\)"$/\1/p' "$1" | tr ' ' '\n' | grep . | sort -u
}
queue_shards="$(queue_fallback_shards "$WORKFLOW")"
grep -qx orch-terminal <<< "$queue_shards" ||
  bad "no queue shard read from $WORKFLOW, so the queue reader is broken"
check "the queue job's fallback names ci-job-set's QUEUE_MACOS_SHARDS" \
  "$(queue_job_set_shards "$JOB_SET")" "$queue_shards"
check "no queue macOS shard is Linux-only" "" \
  "$(comm -12 <(printf '%s\n' "$queue_shards") <(linux_only_shards "$JOB_SET"))"
sed "s/'\[\"orch-terminal\", /'[\"linear-controls\", \"orch-terminal\", /" "$WORKFLOW" > "$TMP/queue-linux.yml"
cmp -s "$WORKFLOW" "$TMP/queue-linux.yml" &&
  bad "must-fail: the queue fallback list is no longer one line in $WORKFLOW"
check "must-fail: a queue fallback naming a Linux-only shard is named" "linear-controls" \
  "$(comm -12 <(queue_fallback_shards "$TMP/queue-linux.yml") <(linux_only_shards "$JOB_SET"))"
sed 's/^QUEUE_MACOS_SHARDS="orch-terminal /QUEUE_MACOS_SHARDS="/' "$JOB_SET" > "$TMP/queue-short-job-set"
cmp -s "$JOB_SET" "$TMP/queue-short-job-set" &&
  bad "must-fail: QUEUE_MACOS_SHARDS no longer starts with orch-terminal in $JOB_SET"
if [[ "$(queue_job_set_shards "$TMP/queue-short-job-set")" != "$queue_shards" ]]; then
  ok "must-fail: a QUEUE_MACOS_SHARDS without orch-terminal disagrees with the queue job"
else
  bad "must-fail: a QUEUE_MACOS_SHARDS without orch-terminal disagrees with the queue job"
fi

# --- 4d. Exactly-once suite coverage on each original shell runner --------
# Linux runs every shell suite. macOS runs the same files except linear's
# Bash-4-only suites, whose existing runtime-contract suite runs under Bash 3.
# The matrix's exclusions must not remove a shell roster on either runner.
# The roster jobs are the Linux job and the main-push macOS job; the merge
# queue's macOS legs run a subset of shards and are no roster.
roster_os() { # WORKFLOW — the os of each roster job's matrix, one per line
  awk '
    /^  [A-Za-z0-9_-]+:/ { job = $1 }
    (job == "skill-suites-shard:" || job == "skill-suites-macos:") && /^        os: \[/ {
      sub(/^        os: \[/, ""); sub(/\]$/, ""); print
    }
  ' "$1" | tr -d ' "' | tr ',' '\n'
}
check "the shell matrix retains each original OS exactly once" \
  $'ubuntu-latest\nmacos-latest' "$(roster_os "$WORKFLOW")"
awk '/^  skill-suites-macos:/ { job = 1 } /^  skill-suites-macos-queue:/ { job = 0 }
     job && $0 == "        os: [macos-latest]" { $0 = "        os: [ubuntu-latest]"; n++ }
     { print } END { exit n != 1 }' "$WORKFLOW" > "$TMP/mac-roster-linux.yml" ||
  bad "must-fail: the main-push macOS os line is no longer one line in $WORKFLOW"
check "must-fail: a main-push roster moved off macOS loses its OS" \
  $'ubuntu-latest\nubuntu-latest' "$(roster_os "$TMP/mac-roster-linux.yml")"
shared_steps() { # WORKFLOW — the Linux anchor and macOS alias
  awk '
    /^  [A-Za-z0-9_-]+:/ { job = $1 }
    /^    steps:/ && (job == "skill-suites-shard:" || job == "skill-suites-macos:" || job == "skill-suites-macos-queue:") { print job " " $2 }
  ' "$1"
}
check "both shell runners use the same suite steps, the queue's macOS legs included" \
  $'skill-suites-shard: &skill-suite-steps\nskill-suites-macos: *skill-suite-steps\nskill-suites-macos-queue: *skill-suite-steps' \
  "$(shared_steps "$WORKFLOW")"
sed 's/steps: \*skill-suite-steps/steps: []/' "$WORKFLOW" > "$TMP/mac-empty.yml"
check "must-fail: a macOS job with no shared steps loses its suite alias" \
  $'skill-suites-shard: &skill-suite-steps\nskill-suites-macos: []\nskill-suites-macos-queue: []' \
  "$(shared_steps "$TMP/mac-empty.yml")"
check "the linear roster has one injectable shell-version branch" "1" \
  "$(grep -cF 'if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then' "$WORKFLOW")"

os_claims() { # <workflow> <os> <major> ; suite files the expanded matrix runs
  local wf="$1" os="$2" major="$3" excluded="" owners="$TMP/os-owners"
  if [[ "$os" == macos-latest ]]; then
    excluded="$(macos_excluded_shards "$wf" | tr '\n' ' ')" || return
  fi
  suite_owners "$wf" files "$major" > "$owners"
  awk -F '\t' -v excluded="$excluded" '
    BEGIN { n = split(excluded, names, " "); for (i = 1; i <= n; i++) skip[names[i]] = 1 }
    NR == FNR { universe[$0] = 1; next }
    !skip[$1] && $2 in universe { print $2 }
  ' "$TMP/os-universe" "$owners" | sort
}

for os in ubuntu-latest macos-latest; do
  major=4
  [[ "$os" != macos-latest ]] || major=3
  cp "$UNIV" "$TMP/os-universe"
  for f in "$ROOT"/skills/linear/tests/*.sh; do
    [[ "$major" != 3 || "$f" == */bash4-runtime-contract.test.sh ]] || continue
    printf '%s\n' "${f#"$ROOT/"}" >> "$TMP/os-universe"
  done
  sort -o "$TMP/os-universe" "$TMP/os-universe"
  [[ -s "$TMP/os-universe" ]] || { bad "the suite discovery is empty for $os"; continue; }
  os_claims "$WORKFLOW" "$os" "$major" > "$TMP/os-claims"
  check "every original suite runs exactly once on $os" \
    "$(cat "$TMP/os-universe")" "$(cat "$TMP/os-claims")"
  printf 'coverage: os=%s suites=%s\n' "$os" "$(wc -l < "$TMP/os-universe" | tr -d ' ')"
  os_claims "$wf_drop" "$os" "$major" > "$TMP/os-drop"
  [[ -n "$(comm -23 "$TMP/os-universe" <(sort -u "$TMP/os-drop"))" ]] &&
    ok "must-fail: an omitted roster leaves suites missing on $os" || bad "omission control named no suite on $os"
  os_claims "$wf_twice" "$os" "$major" > "$TMP/os-twice"
  [[ -n "$(uniq -d "$TMP/os-twice")" ]] &&
    ok "must-fail: a duplicated roster repeats suites on $os" || bad "duplication control named no suite on $os"
done

fi

if [[ "$mode" != shell ]]; then

check "Cargo name checks run only after the macOS CLI rest compile" \
  " --cargo-only:true::matrix.crate == 'kendex-cli' && matrix.leg == 'rest'" \
  "$(partition_cargo_steps "$WORKFLOW")"
for defect in mode order; do
  mutant="$TMP/wf-partition-cargo-$defect.yml"
  case "$defect" in
    mode) sed "s%run: bash $PARTITION_SUITE --cargo-only%run: bash $PARTITION_SUITE --shell-only%" "$WORKFLOW" > "$mutant" ;;
    order) sed 's/--no-run \$CARGO_TARGETS \$CARGO_INTEGRATION/\$CARGO_TARGETS \$CARGO_INTEGRATION/' "$WORKFLOW" > "$mutant" ;;
  esac
  if [[ "$(partition_cargo_steps "$mutant")" != "$(partition_cargo_steps "$WORKFLOW")" ]]; then
    ok "must-fail: Cargo $defect breaks the compile-owner invocation"
  else
    bad "must-fail: Cargo $defect is accepted"
  fi
done

# --- 5. The cargo legs' partition over the CLI's test targets --------------
# A cargo leg is a roster of `--test` names, and the seam it cuts is inside
# one package rather than across the workspace, so the crate guard in that job
# cannot see it. The universe comes from `cargo metadata`, the one reader of a
# crate's target list; the claims come from RUNNING the workflow's own roster
# step once per leg. Claims use its GITHUB_ENV exports, the inputs GitHub
# gives the consumer step. Diagnostic lines remain independent declarations
# for the checks that compare intended selections with executed selections.
#
# The legs are the combinations GitHub expands — the matrix `leg:` list minus
# the `exclude:` entries naming this crate — so a leg the matrix prunes is
# credited with nothing. A leg present in that expansion with no case arm is
# the roster step's own refusal and reds that job, not this file.
#
# Two contracts beside the partition, because a roster of `--test` names alone
# accounts for neither. The bounded leg carries the crate's library and binary
# unit tests, which no `--test` name selects; and the leg the seam exists for
# carries that one target and nothing else, since merging it back into the
# bounded leg undoes the split while leaving the target partition whole.
#
# The two shape reads this section depends on — the matrix leg list and the
# step that echoes a roster — are asserted here rather than inside
# leg_claims, whose callers run it in a pipeline or a substitution where a
# counter bumped in the subshell would be discarded.
CARGO_TARGET_MARK='cargo-targets: $flags'
CARGO_CRATE=kendex-cli
CARGO_LEGS='apply-locked render-lint rest verify-lock'
LANE_LEG=render-lint
LANE_TARGET=catalog_render_lint
UNIT_LEG=rest
UNIT_FLAGS='--lib --bins'
INTEGRATION_TARGET=integration
INTEGRATION_LEGS=$'apply-locked\nrest\nverify-lock'
CARGO_TEST_MARK='cargo test -p ${{ matrix.crate }} --locked --no-fail-fast'

cli_targets() { # cli_targets ; CARGO_CRATE's test target names, one per line
  ( cd "$ROOT" && cargo metadata --format-version 1 --no-deps --locked ) |
    jq -r --arg crate "$CARGO_CRATE" '
      .packages[] | select(.name == $crate)
      | .targets[] | select(.kind[0] == "test") | .name' | sort
}

# The `exclude:` entries naming CARGO_CRATE, read as YAML sequence items: a
# `- ` line opens an item, the lines under it continue it, and a line indented
# less than the item's own column closes the sequence. Indent work is substr
# and not a regex interval — the macOS leg's awk is not GNU's.
cargo_excluded_legs() { # cargo_excluded_legs <workflow> ; legs pruned for CARGO_CRATE
  awk -v crate="$CARGO_CRATE" '
    function flush() { if (c == crate && l != "") print l; c = ""; l = "" }
    NF == 0 || $1 == "#" { next }
    { n = 0; while (substr($0, n + 1, 1) == " ") n++ }
    inx == 1 && n < 10 { flush(); inx = 0 }
    inx == 0 && n == 8 && $1 == "exclude:" { inx = 1; next }
    inx == 0 { next }
    $1 == "-" { flush(); key = $2; val = $3 }
    $1 != "-" { key = $1; val = $2 }
    key == "crate:" { c = val }
    key == "leg:" { l = val }
    END { if (inx == 1) flush() }
  ' "$1" | sort -u
}

cargo_legs_of() { # cargo_legs_of <workflow> ; the CARGO_CRATE legs it expands
  local wf="$1" excluded leg
  excluded="$(cargo_excluded_legs "$wf")"
  while IFS= read -r leg; do
    [[ -n "$leg" ]] || continue
    if ! grep -qxF -e "$leg" <<< "$excluded"; then printf '%s\n' "$leg"; fi
  done < <(sed -n 's/^ \{8\}leg: \[\(.*\)\]$/\1/p' "$wf" | tr -d ' ' |
    tr ',' '\n' | sort -u)
}

roster_of() { # <workflow> <leg> [declarations] ; exports, or diagnostic declarations
  local dir="$TMP/cargo-blocks" f env_file log_file
  split_run_blocks "$1" "$dir"
  for f in "$dir"/*.sh; do
    grep -qF "$CARGO_TARGET_MARK" "$f" || continue
    env_file="$(mktemp "$TMP/github-env.XXXXXX")" || return
    log_file="$env_file.log"
    LEG="$2" GITHUB_ENV="$env_file" "$BASH" "$f" > "$log_file" 2>/dev/null || return
    if [[ "${3-}" == declarations ]]; then
      cat "$log_file"
    else
      cat "$env_file"
    fi
  done
}

leg_claims() { # leg_claims <workflow> ; "<--test name> <leg>" per claim, per leg
  local wf="$1" leg
  while IFS= read -r leg; do
    [[ -n "$leg" ]] || continue
    roster_of "$wf" "$leg" |
      sed -n -e 's/^CARGO_TARGETS=//p' -e 's/^CARGO_INTEGRATION=//p' |
      awk -v leg="$leg" \
        '{ for (i = 1; i <= NF; i++) if ($i == "--test") print $(i + 1), leg }'
  done < <(cargo_legs_of "$wf")
}

# What a leg selects BESIDE its `--test` names: `--lib` and `--bins` are the
# crate's library and binary unit tests, which no target claim can show.
unit_flags_of() { # unit_flags_of <workflow> <leg> ; that leg's other selections
  roster_of "$1" "$2" | sed -n 's/^CARGO_TARGETS=//p' |
    awk '{ out = ""
           for (i = 1; i <= NF; i++) {
             if ($i == "--test") { i++; continue }
             out = out (out == "" ? "" : " ") $i
           }
           print out }'
}

lane_claims_of() { # lane_claims_of <claims file> ; the LANE_LEG leg's claims
  awk -v leg="$LANE_LEG" '$2 == leg { print $1 }' "$1"
}

doc_legs() { # doc_legs <workflow> ; the legs whose roster carries `--doc`
  local wf="$1" leg
  while IFS= read -r leg; do
    [[ -n "$leg" ]] || continue
    # A here-string and not a pipe: `grep -q` stops at the first match, and a
    # shell writer it SIGPIPEs returns 141 under pipefail, which in condition
    # position reads as a leg that asked for no doc tests.
    if grep -qx 'CARGO_DOC=--doc' <<< "$(roster_of "$wf" "$leg")"; then
      printf '%s\n' "$leg"
    fi
  done < <(cargo_legs_of "$wf")
}

leg_count_of() { # leg_count_of <workflow> ; how many legs it expands
  cargo_legs_of "$1" | grep -c . || true
}

roster_steps_of() { # roster_steps_of <workflow> <dir> ; run blocks echoing a roster
  split_run_blocks "$1" "$2"
  { grep -lF "$CARGO_TARGET_MARK" "$2"/*.sh || true; } | wc -l | tr -d ' '
}

# The executable comes from Cargo's build record, not a guessed target path.
# --list is libtest's machine-read list and applies its real substring/skip
# rules without running the CLI's integration tests.
integration_binary() {
  ( cd "$ROOT" && cargo test -p "$CARGO_CRATE" --locked --no-run \
      --test "$INTEGRATION_TARGET" --message-format=json ) > "$TMP/integration-build.jsonl" \
      2> "$TMP/integration-build.err" || return
  cat "$TMP/integration-build.err" >&2
  jq -r --arg target "$INTEGRATION_TARGET" '
    select(.reason == "compiler-artifact" and .profile.test and .target.name == $target)
    | .executable // empty' "$TMP/integration-build.jsonl"
}

# Only Cargo's launch is replaced: its --test selection chooses whether the
# real integration binary gets listed. The workflow still owns argument
# forwarding. Omitting its -- or CARGO_FILTERS therefore breaks these claims.
CARGO_SHIM="$TMP/cargo-shim"
mkdir -p "$CARGO_SHIM"
cat > "$CARGO_SHIM/cargo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1-}" == test ]] || exit 2
shift
integration=false
other=false
selections=''
doc=false
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --test)
      if [[ "$2" == integration ]]; then integration=true; else other=true; fi
      selections="$selections --test $2"
      shift 2 ;;
    --lib|--bins) other=true; selections="$selections $1"; shift ;;
    --doc) doc=true; shift ;;
    --) shift; break ;;
    *) shift ;;
  esac
done
[[ "$other" != true || "$#" -eq 0 ]] || exit 1
if [[ "$doc" == true ]]; then
  echo 'cargo-executed-doc: --doc'
else
  echo "cargo-executed: $selections"
fi
if [[ "$integration" == true ]]; then
  "$INTEGRATION_EXE" --list "$@"
fi
SH
chmod +x "$CARGO_SHIM/cargo"

integration_claims() { # <workflow> ; "<integration test name> <leg>" per claim
  local wf="$1" leg dir="$TMP/cargo-test-blocks" f block roster output
  split_run_blocks "$wf" "$dir"
  for f in "$dir"/*.sh; do
    grep -qF "$CARGO_TEST_MARK" "$f" || continue
    block="$TMP/cargo-test-step.sh"
    sed 's/${{ matrix.crate }}/kendex-cli/g' "$f" > "$block"
    while IFS= read -r leg; do
      [[ -n "$leg" ]] || continue
      roster="$(roster_of "$wf" "$leg")" || return
      output="$(CARGO_TARGETS="$(sed -n 's/^CARGO_TARGETS=//p' <<< "$roster")" \
      CARGO_DOC="$(sed -n 's/^CARGO_DOC=//p' <<< "$roster")" \
      CARGO_FILTERS="$(sed -n 's/^CARGO_FILTERS=//p' <<< "$roster")" \
      CARGO_INTEGRATION="$(sed -n 's/^CARGO_INTEGRATION=//p' <<< "$roster")" \
      INTEGRATION_EXE="$INTEGRATION_EXE" PATH="$CARGO_SHIM:$PATH" "$BASH" "$block")" || return
      printf '%s\n' "$output" > "$TMP/cargo-executed-$leg"
      sed -n 's/: test$//p' <<< "$output" | awk -v leg="$leg" '{ print $0, leg }'
    done < <(cargo_legs_of "$wf")
  done
}

target_selections() { # normalized target switches, independent of invocation order
  awk '{ for (i = 1; i <= NF; i++) {
           if ($i == "--test") { print $i " " $(i + 1); i++ }
           else if ($i == "--lib" || $i == "--bins") print $i
         } }' | sort
}

integration_test_steps_of() { # <workflow> ; run blocks launching Cargo tests
  split_run_blocks "$1" "$TMP/cargo-step-count"
  { grep -lF "$CARGO_TEST_MARK" "$TMP/cargo-step-count"/*.sh || true; } | wc -l | tr -d ' '
}

CLI_TARGETS="$TMP/cli-targets"
CARGO_ERR="$TMP/cargo-metadata.err"
if ! cli_targets > "$CLI_TARGETS" 2> "$CARGO_ERR"; then
  bad "cargo metadata did not run, so no cargo leg roster can be judged: $(head -n 1 "$CARGO_ERR")"
  : > "$CLI_TARGETS"
elif [[ ! -s "$CLI_TARGETS" ]]; then
  bad "cargo metadata reported no test target for $CARGO_CRATE, so the extractor is broken, not the crate sparse"
fi

INTEGRATION_EXE="$(integration_binary)" || {
  cat "$TMP/integration-build.err" >&2
  bad "the integration harness did not compile, so no name partition can be judged"
  exit 1
}
[[ -x "$INTEGRATION_EXE" ]] || { bad "Cargo reported no single executable integration harness"; exit 1; }
INTEGRATION_TESTS="$TMP/integration-tests"
"$INTEGRATION_EXE" --list > "$TMP/integration-list"
sed -n 's/: test$//p' "$TMP/integration-list" | sort > "$INTEGRATION_TESTS"
for module in cli verify_records lock_record toggle_locked; do
  grep -q "^$module::" "$INTEGRATION_TESTS" || {
    bad "the integration test list has no $module member, so discovery is incomplete"
    exit 1
  }
done

[[ "$(leg_count_of "$WORKFLOW")" -gt 0 ]] ||
  bad "no leg matrix in $WORKFLOW, so no cargo leg roster can be judged"
check "exactly one run block echoes a cargo target roster" "1" \
  "$(roster_steps_of "$WORKFLOW" "$TMP/cargo-blocks-head")"
check "exactly one run block launches the macOS Cargo test targets" "1" \
  "$(integration_test_steps_of "$WORKFLOW")"

# The expansion itself, pinned to the legs the splits cut. This is what
# gives the checks below their teeth: an exclude reader that stopped reading
# would put the pruned `whole` leg back, and `whole` selects every target the
# crate has, so every check below would pass over a leg GitHub never creates.
check "the matrix expands the $CARGO_CRATE lane as exactly the legs the split cut" \
  "$CARGO_LEGS" "$(cargo_legs_of "$WORKFLOW" | tr '\n' ' ' | sed 's/ *$//')"

LEG_CLAIMS="$TMP/leg-claims-head"
leg_claims "$WORKFLOW" | sort > "$LEG_CLAIMS"
CLAIMED="$TMP/claimed-head"
cut -d' ' -f1 "$LEG_CLAIMS" | sort > "$CLAIMED"

check "every $CARGO_CRATE test target is claimed by one of the workflow's cargo legs" \
  "" "$(comm -23 "$CLI_TARGETS" <(sort -u "$CLAIMED"))"
check "no $CARGO_CRATE target other than the shared integration harness is claimed twice" \
  "$INTEGRATION_TARGET" "$(uniq -d "$CLAIMED")"
check "only the name-partitioned legs share the integration target" \
  "$INTEGRATION_LEGS" "$(awk -v target="$INTEGRATION_TARGET" '$1 == target { print $2 }' "$LEG_CLAIMS" | sort)"
check "the $UNIT_LEG leg selects the crate's library and binary unit tests" \
  "$UNIT_FLAGS" "$(unit_flags_of "$WORKFLOW" "$UNIT_LEG")"
check "the $LANE_LEG leg claims $LANE_TARGET and nothing else" \
  "$LANE_TARGET" "$(lane_claims_of "$LEG_CLAIMS")"

INTEGRATION_CLAIMS="$TMP/integration-claims"
integration_claims "$WORKFLOW" | sort > "$INTEGRATION_CLAIMS"
# Named tests keep a valid but incomplete --list extractor from proving only
# a module prefix. They also exercise each selector family and rest.
while IFS='|' read -r name leg; do
  if grep -qxF "$name $leg" "$INTEGRATION_CLAIMS"; then
    ok "the named integration test $name belongs to $leg"
  else
    bad "the named integration test $name is missing from $leg"
  fi
done <<'TESTS'
cli::list_sees_global_and_current_project_scopes|rest
cli::verify_names_an_installation_that_cannot_act|verify-lock
lock_record::two_branches_on_one_package_merge_in_sequence_and_main_records_after_each|verify-lock
apply_locked::an_apply_after_a_source_revision_edit_renders_at_that_revision|apply-locked
TESTS
while IFS='|' read -r family leg; do
  check "every $family test belongs to $leg" \
    "$(sed -n "/^$family/p" "$INTEGRATION_TESTS")" \
    "$(awk -v family="$family" -v leg="$leg" 'index($1, family) == 1 && $2 == leg { print $1 }' "$INTEGRATION_CLAIMS")"
done <<'FAMILIES'
toggle_locked::|verify-lock
apply_locked::|apply-locked
FAMILIES
while IFS= read -r leg; do
  check "the $leg test command runs every declared target and unit selection" \
    "$(roster_of "$WORKFLOW" "$leg" declarations | sed -n 's/^cargo-targets: //p' | target_selections)" \
    "$(sed -n 's/^cargo-executed: //p' "$TMP/cargo-executed-$leg" | target_selections)"
  check "the $leg test command runs its declared doc tests" \
    "$(roster_of "$WORKFLOW" "$leg" declarations | sed -n 's/^cargo-doc: //p')" \
    "$(sed -n 's/^cargo-executed-doc: //p' "$TMP/cargo-executed-$leg")"
done < <(cargo_legs_of "$WORKFLOW")
cut -d' ' -f1 "$INTEGRATION_CLAIMS" | sort > "$TMP/integration-claimed"
check "every integration test is claimed by one workflow leg" \
  "" "$(comm -23 "$INTEGRATION_TESTS" <(sort -u "$TMP/integration-claimed"))"
check "no integration test is claimed by two workflow legs" \
  "" "$(uniq -d "$TMP/integration-claimed")"
for leg in apply-locked rest verify-lock; do
  [[ -n "$(awk -v leg="$leg" '$2 == leg { print $1 }' "$INTEGRATION_CLAIMS")" ]] &&
    ok "the $leg leg claims integration tests" || bad "the $leg leg claims no integration test"
done
printf 'coverage: cargo-integration tests=%s\n' "$(wc -l < "$INTEGRATION_TESTS" | tr -d ' ')"

# Doc tests are the one thing a `--test` roster cannot account for. cargo runs
# them only where nothing selects targets, and `--doc` cannot be mixed with a
# selection, so every leg here names targets and owes them a second
# invocation. One leg carrying `--doc` runs the crate's doc tests once; none
# carrying it runs them on Linux and nowhere on this platform, which no
# target claim can show.
check "exactly one cargo leg's roster carries --doc" "1" \
  "$(doc_legs "$WORKFLOW" | grep -c . || true)"

# --- 5b. Must-fail: the ways this partition and its two contracts break ----
# One leg's roster emptied leaves the targets only it named in no leg; a
# target added to a second leg runs twice and pays its seconds twice. An arm
# whose needle stopped matching mutates nothing and reports nothing, which is
# what the else branches and the non-empty expectations say.
wf_leg_drop="$TMP/wf-cargo-leg-dropped.yml"
awk "{ sub(/--test $LANE_TARGET/, \"\"); print }" "$WORKFLOW" > "$wf_leg_drop"
if [[ -n "$(comm -23 "$CLI_TARGETS" <(leg_claims "$wf_leg_drop" | cut -d' ' -f1 | sort -u))" ]]; then
  ok "must-fail: an emptied cargo leg roster leaves its targets unclaimed, and they are named"
else
  bad "must-fail: emptying a cargo leg roster left nothing unclaimed, so the coverage check proves nothing"
fi

wf_leg_twice="$TMP/wf-cargo-leg-repeated.yml"
awk "{ sub(/$UNIT_FLAGS/, \"$UNIT_FLAGS --test $LANE_TARGET\"); print }" \
  "$WORKFLOW" > "$wf_leg_twice"
if grep -qxF "$LANE_TARGET" <<< "$(leg_claims "$wf_leg_twice" | cut -d' ' -f1 | sort | uniq -d)"; then
  ok "must-fail: a target added to a second cargo leg is named as claimed twice"
else
  bad "must-fail: a repeated cargo target produced no duplicate, so the overlap check proves nothing"
fi

# The `--doc` assignment dropped: every leg then selects targets and none asks
# for doc tests, so they run nowhere on this platform.
wf_no_doc="$TMP/wf-cargo-doc-dropped.yml"
awk "{ sub(/doc='--doc'/, \"doc=''\"); print }" "$WORKFLOW" > "$wf_no_doc"
if [[ "$(doc_legs "$wf_no_doc" | grep -c . || true)" -eq 0 ]]; then
  ok "must-fail: with the --doc assignment dropped, no cargo leg asks for doc tests"
else
  bad "must-fail: dropping the --doc assignment left a leg still asking for doc tests, so the count proves nothing"
fi

# `--lib --bins` dropped from the bounded leg: the crate's library and binary
# unit tests are selected nowhere on this platform, and every `--test` name
# still runs, so no coverage or overlap check moves.
wf_no_unit="$TMP/wf-cargo-unit-dropped.yml"
awk "{ sub(/flags='$UNIT_FLAGS'/, \"flags=''\"); print }" "$WORKFLOW" > "$wf_no_unit"
check "must-fail: with $UNIT_FLAGS dropped, the $UNIT_LEG leg selects no unit test" \
  "" "$(unit_flags_of "$wf_no_unit" "$UNIT_LEG")"

# The expensive target merged back into the bounded leg, undoing the split
# this issue exists to make. The leg matrix loses the lane leg and the bounded
# leg's roster gains its target, so every target still runs exactly once and
# only the lane leg's own contract shows that the seam is gone. The first
# check below is this arm's control; the second is the paired claim it rests
# on, and it holds before the mutation as well, which is the point.
wf_lane_merged="$TMP/wf-cargo-lane-merged.yml"
awk "{
       sub(/leg: \[whole, $LANE_LEG, /, \"leg: [whole, \")
       sub(/flags='$UNIT_FLAGS'/, \"flags='$UNIT_FLAGS --test $LANE_TARGET'\")
       print
     }" "$WORKFLOW" > "$wf_lane_merged"
merged="$TMP/leg-claims-lane-merged"
leg_claims "$wf_lane_merged" | sort > "$merged"
check "must-fail: with $LANE_TARGET merged into the $UNIT_LEG leg, the $LANE_LEG leg claims nothing" \
  "" "$(lane_claims_of "$merged")"
check "must-fail: that merge retains every target and only the integration overlap" \
  ":$INTEGRATION_TARGET" "$(comm -23 "$CLI_TARGETS" <(cut -d' ' -f1 "$merged" | sort -u)):$(cut -d' ' -f1 "$merged" | sort | uniq -d)"

# Omission and overlap controls remove one side of the same name seam.
# A third control drops forwarding in the actual test command: declarations
# alone must not claim protection for arguments the harness never receives.
for defect in selector skip toggle-selector toggle-skip apply-leg-drop apply-skip forwarding export unit-filter; do
  mutant="$TMP/wf-cargo-filter-$defect.yml"
  case "$defect" in
    selector) sed "s/filters='verify_ lock_record:: toggle_locked::'/filters='lock_record:: toggle_locked::'/" "$WORKFLOW" > "$mutant" ;;
    skip) sed 's/--skip verify_ //' "$WORKFLOW" > "$mutant" ;;
    toggle-selector) sed "s/filters='verify_ lock_record:: toggle_locked::'/filters='verify_ lock_record::'/" "$WORKFLOW" > "$mutant" ;;
    toggle-skip) sed 's/ --skip toggle_locked:://' "$WORKFLOW" > "$mutant" ;;
    apply-leg-drop) sed 's/, apply-locked\]/]/' "$WORKFLOW" > "$mutant" ;;
    apply-skip) sed 's/ --skip apply_locked:://' "$WORKFLOW" > "$mutant" ;;
    forwarding) sed 's/ -- \$CARGO_FILTERS//' "$WORKFLOW" > "$mutant" ;;
    export) sed 's/echo "CARGO_FILTERS=\$filters"/echo "CARGO_FILTERS="/' "$WORKFLOW" > "$mutant" ;;
    unit-filter) sed 's/\$CARGO_TARGETS ||/\$CARGO_TARGETS -- \$CARGO_FILTERS ||/' "$WORKFLOW" > "$mutant" ;;
  esac
  cmp -s "$WORKFLOW" "$mutant" && { bad "must-fail: the $defect mutation changed nothing"; continue; }
  if [[ "$defect" == export ]]; then
    check "the export control preserves the roster declarations" \
      "$(roster_of "$WORKFLOW" "$UNIT_LEG" declarations)" \
      "$(roster_of "$mutant" "$UNIT_LEG" declarations)"
  fi
  if [[ "$defect" == unit-filter ]]; then
    if integration_claims "$mutant" > "$TMP/integration-$defect"; then
      bad "must-fail: integration filters on unit tests are accepted"
    else
      ok "must-fail: integration filters on unit tests are rejected"
    fi
    continue
  fi
  integration_claims "$mutant" | cut -d' ' -f1 | sort > "$TMP/integration-$defect"
  if [[ "$defect" == selector || "$defect" == toggle-selector || "$defect" == apply-leg-drop ]]; then
    lost="$(comm -23 "$INTEGRATION_TESTS" <(sort -u "$TMP/integration-$defect"))"
    if [[ "$defect" == toggle-selector || "$defect" == apply-leg-drop ]]; then
      family=toggle_locked::
      [[ "$defect" != apply-leg-drop ]] || family=apply_locked::
      check "must-fail: dropped $defect leaves every $family test unclaimed" \
        "$(sed -n "/^$family/p" "$INTEGRATION_TESTS")" "$lost"
    else
      [[ -n "$lost" ]] && ok "must-fail: a dropped selector names unclaimed integration tests" ||
        bad "must-fail: a dropped selector leaves no unclaimed integration test"
    fi
  else
    repeated="$(uniq -d "$TMP/integration-$defect")"
    if [[ "$defect" == toggle-skip || "$defect" == apply-skip ]]; then
      family=toggle_locked::
      [[ "$defect" != apply-skip ]] || family=apply_locked::
      check "must-fail: dropped $defect repeats every $family test" \
        "$(sed -n "/^$family/p" "$INTEGRATION_TESTS")" "$repeated"
    else
      [[ -n "$repeated" ]] && ok "must-fail: dropped $defect names repeated integration tests" ||
        bad "must-fail: dropped $defect leaves no repeated integration test"
    fi
  fi
done

# The two shapes this section reads, each deleted. Neither loss shows in a
# claim: with no leg matrix no leg is read at all, and with no roster step no
# leg claims anything, so both would leave the checks above green over an
# empty set of claims.
wf_no_legs="$TMP/wf-cargo-leg-matrix-deleted.yml"
grep -v '^        leg: \[' "$WORKFLOW" > "$wf_no_legs"
check "must-fail: with the leg matrix deleted, the leg read finds none" "0" \
  "$(leg_count_of "$wf_no_legs")"

wf_no_roster="$TMP/wf-cargo-roster-step-deleted.yml"
awk '
  index($0, "- name: cargo test targets for this leg") { drop = 1; next }
  drop == 1 && substr($0, 1, 8) == "      - " { drop = 0 }
  drop == 1 { next }
  { print }
' "$WORKFLOW" > "$wf_no_roster"
check "must-fail: with the roster step deleted, no run block echoes a cargo target roster" \
  "0" "$(roster_steps_of "$wf_no_roster" "$TMP/cargo-blocks-no-roster")"

fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
