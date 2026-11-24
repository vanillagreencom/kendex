#!/usr/bin/env bash
# The workflow's shell rosters must cover every eligible suite once, the orch
# battery's two shards, orch-state and orch-rest, among them. Tools, hooks
# and skills keep their own suites even where they share a runner.
# Missing, duplicate and wrong-shard controls judge the workflow's real calls.
#
# It reaches the cargo lanes too. The macOS kendex-cli lane runs as legs over
# `--test` targets, and the crate guard inside that job spells the workspace
# MEMBERS and covers no list of targets, so a test file added under
# crates/cli/tests and named by no leg would compile under `--no-run` and run
# nowhere while both required cargo contexts stayed green.
#
# The shell roster is real and the suites are not: every shell run happens in a
# sandbox holding a copy of run-all.sh and one stub file per suite name, or a
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
unset TEMPORARY_SUITE MAIN_ONLY_FILTERS

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
# A fixture suite runs nothing real and prints one passing row, since
# run-all.sh reds a suite that exits 0 with no row counted.
stub_suite() { # stub_suite <path>
  printf '#!/usr/bin/env bash\nprintf '\''pass: 1   fail: 0\\n'\''\n' > "$1"
}

# One record per step carrying a `run: |` block or a one-line battery call: the step's `if:` text on the
# `@@` line, its dedented body on the `>` lines. Every body line is prefixed,
# so a body opening with `@` or `>` is not read as a boundary. Indent work is
# substr and not a regex interval — the macOS leg's awk is not GNU's.
BLOCK_AWK="$TMP/run-blocks.awk"
cat > "$BLOCK_AWK" <<'AWK'
substr($0, 1, 8)  == "      - "       { inrun = 0; cond = "" }
substr($0, 1, 12) == "        if: "   { cond = substr($0, 13); next }
substr($0, 1, 14) == "        run: |" { inrun = 1; printf "@@%s\n", cond; next }
substr($0, 1, 13) == "        run: " {
  run = substr($0, 14)
  if (index(run, "bash skills/orch/tests/run-all.sh --battery ") == 1 || index(run, "bash tools/tests/run-all.sh") == 1)
    printf "@@%s\n>%s\n", cond, run
  next
}
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
SANDBOX="$TMP/routing/skills/orch/tests"
mkdir -p "$SANDBOX/lib" "$TMP/routing/skills/github/scripts/lib" "$TMP/routing/tools"
cp "$ROOT/tools/macos-test-contracts" "$ROOT/tools/macos-test-contracts.json" "$TMP/routing/tools/"
cp "$TEST_DIR/run-all.sh" "$SANDBOX/run-all.sh"
cp "$TEST_DIR/lib/suite-process.sh" "$SANDBOX/lib/suite-process.sh"
cp "$ROOT/skills/github/scripts/lib/group-leader.sh" "$TMP/routing/skills/github/scripts/lib/group-leader.sh"
printf '#!/usr/bin/env bash\n: # the sandbox clears nothing; its suites are empty\n' \
  > "$SANDBOX/lib/git-env.sh"
roster=""
for f in "$TEST_DIR"/*.sh; do
  base="$(basename "$f" .sh)"
  [[ "$base" == "run-all" ]] && continue
  stub_suite "$SANDBOX/$base.sh"
  roster="$roster$base
"
done
roster="$(printf '%s' "$roster" | sort)"

selected() { # selected <filter>... ; the suite names that ran, sorted
  local native=""
  [[ "${PARTITION_NATIVE:-false}" != true ]] || native="$TMP/routing/tools/macos-test-contracts"
  RUN_ALL_NATIVE_CONTRACTS="$native" RUNNER_OS="${PARTITION_RUNNER_OS:-Linux}" bash "$SANDBOX/run-all.sh" "$@" 2>/dev/null |
    sed -n 's/^──── \(.*\) ────$/\1/p' | sort
}
status_of() { # status_of <filter>... ; the exit status, output discarded
  local rc=0
  RUNNER_OS="${PARTITION_RUNNER_OS:-Linux}" bash "$SANDBOX/run-all.sh" "$@" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

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
one_shard() { # if text ; the shard it names when it names exactly one
  local names
  names="$(grep -oE "matrix\.shard == '[^']+'" <<< "$1" | cut -d"'" -f2)" || names=""
  [[ -n "$names" && "$names" != *$'\n'* ]] && printf '%s' "$names"
  return 0
}

# --- 3. The shell shards' partition over every suite FILE -------------------
# The workflow roster seam is coarser than the shared runner filters: steps discover suite rosters
# of suite files, and since two of them name individual paths inside a package
# another one globs, the file-level partition can no longer be read off the
# globs. The commit-guards, hooks, tools and rest steps also
# carry a fallback: each runs a suite another step claims only while that
# step's path or glob is missing from the workflow's run text. A fallback
# satisfied by a path written in a COMMENT would let two shards both skip the
# same suite and both exit 0. The aggregator asserts job success, never
# suite count, so nothing downstream sees the loss.
#
# Rosters come from each step's run block in a sandbox whose workflow is the
# copy under test and whose trees are this checkout. A `bash` shim leaves
# serial suite calls empty and runs pooled calls over stub suite copies.
# The shim reports suite calls from the real globs, skip arms and filters.
#

# The sandbox: the workflow under test at the path a step's `$wf` spells, and
# the real trees its globs expand over.
PART="$TMP/partition"
mkdir -p "$PART/.github/workflows"
ln -s "$ROOT/skills" "$PART/skills"
mkdir -p "$PART/tools"
for tool in "$ROOT"/tools/*; do
  [[ "${tool##*/}" != rust-reads ]] || continue
  ln -s "$tool" "$PART/tools/${tool##*/}"
done
# The roster sandbox has no Cargo workspace. Record the dependency call,
# while the reader's own suite checks its metadata and source derivation.
cat > "$PART/tools/rust-reads" <<'SH'
#!/bin/sh
[ "$*" = '--cli-smoke .' ] || exit 2
[ -z "${TOOLS_PREP_RECORD:-}" ] || printf 'prepare\n' >> "$TOOLS_PREP_RECORD"
printf 'metadata\n'
if [ "${TOOLS_PREP_RESULT:-0}" -ne 0 ]; then
  printf 'rust-reads: unreadable=cli-smoke\n' >&2
fi
exit "${TOOLS_PREP_RESULT:-0}"
SH
chmod +x "$PART/tools/rust-reads"
ln -s "$ROOT/hooks"  "$PART/hooks"
ln -s "$ROOT/refresh" "$PART/refresh"
# Pooled calls use the real runners over stub copies of the suite files.
# This preserves their discovery and filters without starting the batteries.
POOL="$TMP/pool"
mkdir -p "$POOL/skills/orch/tests/lib" "$POOL/tools/tests" "$TMP/pool-claims"
mkdir -p "$POOL/skills/github/scripts/lib"
cp "$TEST_DIR/run-all.sh" "$POOL/skills/orch/tests/run-all.sh"
cp "$TEST_DIR/lib/git-env.sh" "$POOL/skills/orch/tests/lib/git-env.sh"
cp "$TEST_DIR/lib/suite-process.sh" "$POOL/skills/orch/tests/lib/suite-process.sh"
cp "$ROOT/skills/github/scripts/lib/group-leader.sh" "$POOL/skills/github/scripts/lib/group-leader.sh"
cp "$ROOT/tools/tests/run-all.sh" "$POOL/tools/tests/run-all.sh"
cp "$ROOT/tools/macos-test-contracts" "$ROOT/tools/macos-test-contracts.json" "$POOL/tools/"
for f in "$ROOT"/skills/*/tests/*.sh "$ROOT"/tools/tests/*.test.sh "$ROOT"/hooks/tests/*.sh "$ROOT"/refresh/tests/*.test.sh; do
  [[ "${f##*/}" != run-all.sh ]] || continue
  path="${f#"$ROOT"/}"
  mkdir -p "$POOL/${path%/*}"
  stub_suite "$POOL/$path"
done
# Ownership readers consume the shim's suite-invoked marker. Workflow
# headings do not prove a suite call. A pooled invocation reports the files
# its real runner selects over immutable stub batteries.
SHIM="$TMP/shim"
mkdir -p "$SHIM"
# GitHub hands every run step a GITHUB_ENV file, where a suite step records
# that its suite list left a candidate out; the steps run here get one too.
STEP_ENV="$TMP/step-env"
printf '#!%s\n' "$BASH" > "$SHIM/bash"
cat >> "$SHIM/bash" <<'SH'
set -euo pipefail
# A step's suite list query runs as itself: it starts no suite.
[ "${1-}:${2-}" != tools/ci-job-set:--suite-list ] || exec "$BASH" "$@"
[ -z "${TOOLS_PREP_RECORD:-}" ] || printf 'suite\n' >> "$TOOLS_PREP_RECORD"
case "$1:${2-}" in
  tools/tests/run-all.sh:*) battery=tools/tests ;;
  skills/orch/tests/run-all.sh:--battery) battery="$3" ;;
  *) battery='' ;;
esac
if [[ -n "$battery" ]]; then
  batteries=()
  prior=''
  for word in "$@"; do
    [[ "$prior" != --battery ]] || batteries+=("$word")
    prior="$word"
  done
  key="${RUN_ALL_NATIVE_CONTRACTS:+native}-${RUNNER_OS:-}-$(printf '%s\n' "$@" | cksum | tr ' ' '-')"
  cache="$PARTITION_POOL_CLAIMS/$key"
  if [[ ! -f "$cache" ]]; then
    # No job deadline or inherited pool bound applies to stub fixture suites.
    (cd "$PARTITION_POOL" && env -u RUN_ALL_DEADLINE_EPOCH -u RUN_ALL_SUITE_SECS \
      PATH="$PARTITION_HOST_PATH" "$BASH" "$@") >"$cache.out" || exit 1
    if [[ "${#batteries[@]}" -le 1 ]]; then
      sed -n "s%^──── \(.*\) ────\$%suite-invoked: $battery/\1.sh%p" "$cache.out" > "$cache"
    else
      : > "$cache"
      while IFS= read -r name; do
        found=0
        for root in "${batteries[@]}"; do
          tree="${root%/tests}"; tree="${tree##*/}"
          case "$name" in
            "$tree"--*) printf 'suite-invoked: %s/%s.sh\n' "$root" "${name#"$tree"--}" >> "$cache"; found=1 ;;
          esac
        done
        [[ "$found" = 1 ]] || exit 2
      done < <(sed -n 's/^──── \(.*\) ────$/\1/p' "$cache.out")
    fi
  fi
  cat "$cache"
  exit 0
fi
printf 'suite-invoked: %s\n' "$1"
if [ "$1" = tools/tests/orch-shard-partition.test.sh ]; then
  shift
  printf 'partition-arguments: %s\n' "$*"
fi
exit 0
SH
chmod +x "$SHIM/bash"
export PARTITION_POOL="$POOL" PARTITION_POOL_CLAIMS="$TMP/pool-claims" PARTITION_HOST_PATH="$PATH"

# Serial blocks carry the path marker. Pooled blocks invoke a battery runner.
ROSTER_MARK='=== $t'
roster_block() { # FILE ; a serial roster or a pooled battery invocation
  # A battery under $RUNNER_TEMP is one the step writes as it runs, such as
  # the Rust targets step's cargo units, so it holds no suite of this tree.
  grep -qF -e "$ROSTER_MARK" -e 'bash tools/tests/run-all.sh' "$1" ||
    { grep -qF 'bash skills/orch/tests/run-all.sh' "$1" &&
      awk 'index($0, "--battery") && !index($0, "--battery \"$RUNNER_TEMP/") { found = 1 } END { exit !found }' "$1"; }
}

run_roster_step() (
  cd "$PART" || exit 1
  # The enclosing main-push job's selection applies to that job's candidates.
  # The synthetic step judges the workflow's own unfiltered roster.
  env -u SKIPPED_SUITES GITHUB_ENV="$STEP_ENV" PATH="$SHIM:$PATH" "$BASH" "$1"
)

# Run the actual steps with GitHub's default bash -e and an unreadable list.
split_run_blocks "$WORKFLOW" "$TMP/selector-blocks"
for shard in orch-state orch-rest; do
  result=''
  for block in "$TMP/selector-blocks"/*.sh; do
    grep -qxF "matrix.shard == '$shard'" "${block%.sh}.cond" || continue
    grep -qF -- "--shard $shard" "$block" || continue
    rc=0
    (cd "$PART" && SKIPPED_SUITES=unreadable GITHUB_ENV="$STEP_ENV" PATH="$SHIM:$PATH" "$BASH" -e "$block") \
      >"$TMP/selector-step.log" 2>&1 || rc=$?
    result="$result$rc|$(cat "$TMP/selector-step.log")"
  done
  check "$shard fails when the suite selector refuses its list" \
    '2|ci-job-set: cause=suite-skips-unreadable' "$result"
done

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
    run_roster_step "$f" 2>/dev/null |
      sed -n 's/^suite-invoked: //p'
  done
  direct_claims "$wf"
}

# `linear` is out of the file-level accounting on purpose: its step runs the
# whole package under Bash 4 and the one runtime-contract suite under Bash 3,
# so its roster depends on the leg. Its package is judged by the glob claim
# below instead.
LINEAR_PREFIX='skills/linear/tests/'

claims_file() { # claims_file <workflow> <out> ; the sorted claim list
  claims_of "$1" | grep -v "^$LINEAR_PREFIX" | sort > "$2" || true
}

shell_partition_args() { # <workflow> ; actual arguments from the shell roster invocation
  local wf="$1" dir="$TMP/partition-mode-blocks" f
  cp "$wf" "$PART/.github/workflows/skill-tests.yml"
  split_run_blocks "$wf" "$dir"
  for f in "$dir"/*.sh; do
    grep -qF "$ROSTER_MARK" "$f" || continue
    run_roster_step "$f" 2>/dev/null |
      sed -n 's/^partition-arguments: //p'
  done
}

# The universe comes from source discovery.
UNIV="$TMP/universe"
(
  cd "$ROOT" || exit 1
  for f in skills/*/tests/*.sh tools/tests/*.test.sh hooks/tests/*.sh refresh/tests/*.test.sh; do
    [[ "$f" != skills/orch/tests/run-all.sh ]] || continue
    case "$f" in "$LINEAR_PREFIX"*) continue ;; esac
    # A package's run-all.sh runs its suites through the orch runner; it is none.
    case "$f" in */tests/run-all.sh) continue ;; esac
    printf '%s\n' "$f"
  done
) | sort > "$UNIV"

HEAD_CLAIMS="$TMP/claims-head"
claims_file "$WORKFLOW" "$HEAD_CLAIMS"

edited() { # edited <original> <copy> <arm> ; fails the arm whose edit matched nothing
  if cmp -s -- "$1" "$2"; then
    bad "mutation-unmatched arm=[$3]: the copy equals $(basename -- "$1"), so the arm judges nothing"
  fi
}

pooled_fault() { # FAULT; the current pooled table row supplies its suite
  local fault="$1" mutant got
  mutant="$TMP/wf-pooled-$fault.yml"
  awk -v step="$step" -v battery="$battery" -v stem="$stem" -v fault="$fault" '
    index($0, "- name: " step) { active = 1 }
    active && substr($0, 1, 8) == "      - " && !index($0, "- name: " step) { active = 0 }
    active && index($0, "bash skills/orch/tests/run-all.sh") { call = 1 }
    call && /\\$/ { print; next }
    call {
      if (fault == "omitted") {
        # Every root and --alone option precedes these shared filters.
        if ($0 ~ / \|\| /) sub(/ \|\| /, " !=" stem " || ")
        else $0 = $0 " !=" stem
      }
      # Quoted battery paths execute without answering the fallback claim search.
      else if ($0 ~ /^ *run: /) {
        sub(/run: /, "run: |\n          ")
        $0 = $0 "\n          bash skills/orch/tests/run-all.sh --battery \"" battery "\" =" stem
      } else {
        print
        print "          bash skills/orch/tests/run-all.sh --battery \"" battery "\" =" stem
        hits++; call = 0; next
      }
      hits++
      call = 0
    }
    { print }
    END { exit hits != 1 }
  ' "$WORKFLOW" > "$mutant" || { bad "pooled $fault control matched other than once: $step $battery"; return 1; }
  edited "$WORKFLOW" "$mutant" "pooled-$fault $step $battery"
  if [[ "$battery" == skills/linear/tests ]]; then
    # Unlike claims_file, shard_owners includes the shell-version roster.
    suite_owners "$mutant" files > "$TMP/pooled-owner-claims"
    cut -f 2 "$TMP/pooled-owner-claims" | sort > "$TMP/pooled-fault-claims"
    suite_owners "$WORKFLOW" files > "$TMP/pooled-head-owners"
    cut -f 2 "$TMP/pooled-head-owners" | sort > "$TMP/pooled-head-claims"
  else
    claims_file "$mutant" "$TMP/pooled-fault-claims"
    cp "$HEAD_CLAIMS" "$TMP/pooled-head-claims"
  fi
  case "$fault" in
    omitted) got="$(comm -23 "$TMP/pooled-head-claims" "$TMP/pooled-fault-claims")" ;;
    duplicated) got="$(comm -13 <(uniq -d "$TMP/pooled-head-claims") <(uniq -d "$TMP/pooled-fault-claims"))" ;;
  esac
  check "must-fail: pooled $fault names its suite: $step $battery" "$path" "$got"
}

POOLED_ROWS='rest|all other skill suites|skills/github/tests|check-review-replies-threads.test'

# These three controls must reject their private mutants before baseline assertions.
baseline_tmp="$TMP"
baseline_part="$PART"
CONTROL_TMP="$(mktemp -d)" || { bad "control scratch allocation failed"; exit 1; }
[[ -d "$CONTROL_TMP" && ! -L "$CONTROL_TMP" ]] || exit 1
CONTROL_TMP="$(cd -- "$CONTROL_TMP" && pwd -P)" || exit 1
trap 'rm -rf -- "${baseline_tmp:?}" "${CONTROL_TMP:?}"' EXIT
cp -R "$PART" "$CONTROL_TMP/partition"
TMP="$CONTROL_TMP"
PART="$CONTROL_TMP/partition"

# Dedicated owners disappear independently. Their declarations and the
# generic rest invocation must not answer the claims search themselves.
for package in slack review-gate jarvis; do
  owner=""
  case "$package" in
    slack) owner="- name: Slack suites" ;;
    review-gate) owner="- name: review-gate suites" ;;
    jarvis) owner="- name: Jarvis suites" ;;
  esac
  wf_owner_removed="$TMP/wf-owner-removed-$package.yml"
  awk -v owner="$owner" -v package="$package" '
    owner != "" && index($0, owner) { drop = 1; hits++; next }
    drop && substr($0, 1, 8) == "      - " { drop = 0 }
    drop { next }
    { print }
    END { exit hits == 0 }
  ' "$WORKFLOW" > "$wf_owner_removed" || bad "$package owner removal matched nothing"
  edited "$WORKFLOW" "$wf_owner_removed" "$package-owner-removed"
done

# Each orch shard is one step's. Dropping a step leaves the suites shard_of
# gives that shard in no shard: the rest step still finds the orch battery
# claimed by the other two steps, so it runs none of them.
wf_orch_dropped="$TMP/wf-orch-state-dropped.yml"
awk '
  index($0, "- name: '"'"'orch suites: the lane and workflow-state suites") { drop = 1; hits++; next }
  drop && substr($0, 1, 8) == "      - " { drop = 0 }
  drop { next }
  { print }
  END { exit hits != 1 }
' "$WORKFLOW" > "$wf_orch_dropped" || bad "orch-state step removal matched other than once"
edited "$WORKFLOW" "$wf_orch_dropped" orch-state-dropped
claims_file "$wf_orch_dropped" "$TMP/orch-state-dropped"
check "must-fail: a dropped orch shard step leaves its suites in no shard" \
  "$(selected --shard orch-state | sed 's#^#skills/orch/tests/#; s#$#.sh#' | sort)" \
  "$(comm -23 <(sort -u "$HEAD_CLAIMS") <(sort -u "$TMP/orch-state-dropped"))"
[[ "$FAIL" -eq 0 ]] || exit 1
printf 'control: orch-state-dropped suites=%s\n' "$(comm -23 <(sort -u "$HEAD_CLAIMS") <(sort -u "$TMP/orch-state-dropped")| wc -l | tr -d ' ')"

# The old literal Slack declaration answered its own search after removal.
wf_self_claim="$TMP/wf-slack-self-claim.yml"
awk '
  /github \| slack \| mailbox \| orch\) needle="--battery skills\/\$x\/tests"/ {
    $0 = "              github | slack | mailbox | orch) if [ \"$x\" = slack ]; then needle=\"--battery skills/slack/tests\"; else needle=\"--battery skills/$x/tests\"; fi ;;"; hits++
  }
  { print }
  END { exit hits != 1 }
' "$TMP/wf-owner-removed-slack.yml" > "$wf_self_claim" || bad "Slack self-claim control matched other than once"
edited "$TMP/wf-owner-removed-slack.yml" "$wf_self_claim" slack-self-claim
# The enclosing main-push selection can skip an unrelated hook.
SKIPPED_SUITES='["hooks/tests/block-argv-kill.test.sh"]' \
  claims_file "$wf_self_claim" "$TMP/claims-self-claim"
check "must-fail: a Slack declaration that claims itself loses the reclaimed package" \
  "$(grep '^skills/slack/tests/' "$UNIV")" \
  "$(comm -23 "$UNIV" <(sort -u "$TMP/claims-self-claim"))"

[[ "$FAIL" -eq 0 ]] || exit 1
printf 'control: slack-only omitted=%s\n' "$(comm -23 "$UNIV" <(sort -u "$TMP/claims-self-claim") | wc -l | tr -d ' ')"

while IFS='|' read -r shard step battery stem; do
  [[ "$battery" == skills/github/tests ]] || continue
  path="$battery/$stem.sh"
  pooled_fault duplicated
  [[ "$FAIL" -eq 0 ]] || exit 1
  printf 'control: github-duplicate suites=%s invocations=%s\n' "$(uniq -d "$TMP/pooled-fault-claims" | wc -l | tr -d ' ')" "$(grep -xcF "$path" "$TMP/pooled-fault-claims")"
done <<< "$POOLED_ROWS"

TMP="$baseline_tmp"
PART="$baseline_part"

# --- 1. The filter ----------------------------------------------------------
check "no filter runs the whole battery" "$roster" "$(selected)"
# run-all.sh matches a filter anywhere in a suite's name, so every expectation
# here is a substring match: a prefix match drops a suite that carries the
# filter mid-name.
check "a bare argument selects by substring" \
  "$(printf '%s\n' "$roster" | grep -F 'copilot')" "$(selected copilot)"
check "two arguments are a union, not an intersection" \
  "$(printf '%s\n' "$roster" | grep -F -e 'copilot' -e 'lane')" \
  "$(selected copilot lane)"
check "an argument written !name rejects what it matches" \
  "$(printf '%s\n' "$roster" | grep -vF 'copilot')" "$(selected '!copilot')"
check "a rejector overrides a selector that also matches" \
  "$(printf '%s\n' "$roster" | grep -F 'lane' | grep -vF 'copilot')" \
  "$(selected lane copilot '!copilot')"
check "an empty argument refuses instead of running everything" \
  "1" "$(status_of '')"
check "a filter matching no suite exits non-zero" \
  "1" "$(status_of no-suite-carries-this-name)"
check "a shard and exact selector intersect" \
  "lane-marker" "$(selected --shard orch-state =lane-marker)"
check "a shard and exact rejector intersect" \
  "$(selected --shard orch-state | grep -vxF lane-marker)" \
  "$(selected --shard orch-state '!=lane-marker')"
# A narrowed shard step rejects every suite its suite list skipped, which can
# be every suite of its shard: that leg runs none and passes.
set --
for name in $(selected --shard orch-state); do set -- "$@" "!=$name"; done
check "a shard whose rejectors reject each of its suites runs none and passes" \
  "0|" "$(status_of --shard orch-state "$@")|$(selected --shard orch-state "$@")"
# A main push's main-only rejector can reject the one suite a step's list
# kept: that step runs none and passes. A selector that takes no suite still
# refuses beside a rejector.
check "an exact selector whose suite a rejector rejects runs none and passes" \
  "0|" "$(status_of '=lane-marker' '!=lane-marker')|$(selected '=lane-marker' '!=lane-marker')"
check "a selector that takes no suite refuses beside a rejector" \
  "1" "$(status_of '=no-suite-carries-this-name' '!=lane-marker')"
for args in '--shard' '--shard unknown' '--shard orch-rest =lane-marker'; do
  # These words are the argument contract under test, with no shell quoting.
  # shellcheck disable=SC2086
  check "invalid or empty shard selection refuses: $args" "1" "$(status_of $args)"
done
check "an empty shard filter refuses" "1" "$(status_of --shard orch-state '')"
# Remove only composition from the disposable runner. The suite still exists
# and belongs to the same shard, so this control detects a status-blind shard.
cp "$SANDBOX/run-all.sh" "$TMP/composition-runner"
sed 's/\[ "$OWNING_SHARD" = "$SHARD" \] || return 1/[ "$OWNING_SHARD" = "$SHARD" ]; return/' \
  "$TMP/composition-runner" > "$SANDBOX/run-all.sh"
cmp -s "$TMP/composition-runner" "$SANDBOX/run-all.sh" && { bad "composition control matched nothing"; exit 1; }
if [[ "$(selected --shard orch-state =lane-marker)" != lane-marker ]]; then
  ok "must-fail: a shard that ignores its exact filter violates composition"
else
  bad "must-fail: the exact filter accepted a shard that ignores filters"
fi
cp "$TMP/composition-runner" "$SANDBOX/run-all.sh"

# Execute the real tools blocks with the same dependency boundary as the
# roster checks. A failed preparation must stop before any suite starts.
cp "$WORKFLOW" "$PART/.github/workflows/skill-tests.yml"
split_run_blocks "$WORKFLOW" "$TMP/preparation-blocks"
for block in "$TMP/preparation-blocks"/*.sh; do
  shard="$(one_shard "$(cat "${block%.sh}.cond")")"
  case "$shard" in guards-tools|guards-tools-tail) ;; *) continue ;; esac
  # The macOS Jarvis step on guards-tools runs no tools suite.
  grep -qF 'tools/tests/' "$block" || continue
  platform=Linux
  for defect in none late swallowed; do
      awk -v defect="$defect" '
        /tools\/rust-reads --cli-smoke/ {
          call=$0; n++
          if (defect == "missing" || defect == "late") next
          if (defect == "swallowed") sub(/\|\| exit \$\?$/, "|| true")
        }
        { print }
        END { if (defect == "late") print call; exit n != 1 }
      ' "$block" > "$TMP/preparation-step" || { bad "preparation control has no unique call: $shard"; continue; }
      for result in 0 2; do
        : > "$TMP/preparation-record"
        rc=0
        (cd "$PART" && env -i "PATH=$SHIM:$PATH" "HOME=$HOME" "GITHUB_ENV=$STEP_ENV" \
          "RUNNER_OS=$platform" "TOOLS_PREP_RESULT=$result" "TOOLS_PREP_RECORD=$TMP/preparation-record" \
          "PARTITION_POOL=$POOL" "PARTITION_POOL_CLAIMS=$TMP/pool-claims" "PARTITION_HOST_PATH=$PATH" \
          "$BASH" --noprofile --norc -e -o pipefail "$TMP/preparation-step") \
          > "$TMP/preparation-out" 2> "$TMP/preparation-err" || rc=$?
        valid=no
        first="$(sed -n '1p' "$TMP/preparation-record")"
        if [[ "$result" -eq 0 && "$rc" -eq 0 && "$first" == prepare ]] &&
           grep -qx suite "$TMP/preparation-record" &&
           ! grep -qx metadata "$TMP/preparation-out"; then valid=yes; fi
        if [[ "$result" -eq 2 && "$rc" -eq 2 && "$(cat "$TMP/preparation-record")" == prepare ]] &&
           grep -qx 'rust-reads: unreadable=cli-smoke' "$TMP/preparation-err"; then valid=yes; fi
        expected=no
        if [[ "$defect" == none || "$defect:$result" == swallowed:0 ]]; then expected=yes; fi
        check "tools preparation: $platform $shard $defect result=$result" "$expected" "$valid"
      done
  done
done

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
sed "s%$PARTITION_SUITE)\"%)\"%" "$WORKFLOW" > "$wf_no_shell_partition"
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

# The new hooks shard owns its name seam and md-refs. Each check reads
# the workflow's real loop through the same sandbox as the full partition.
shard_claims() { # WORKFLOW SHARD ; sorted suite files that shard runs
  local wf="$1" shard="$2" dir="$TMP/shard-blocks" f
  cp "$wf" "$PART/.github/workflows/skill-tests.yml"
  split_run_blocks "$wf" "$dir"
  for f in "$dir"/*.sh; do
    [[ "$(one_shard "$(cat "${f%.sh}.cond")")" == "$shard" ]] || continue
    roster_block "$f" || continue
    run_roster_step "$f" 2>/dev/null |
      sed -n 's/^suite-invoked: //p'
  done | sort
}
hook_tail_expected="$(cd "$ROOT" && printf '%s\n' hooks/tests/lane-mail-*.test.sh \
  hooks/tests/reviewer-*.test.sh | sort)"
hook_tail_claims="$(shard_claims "$WORKFLOW" guards-hooks-tail)"
hook_kept_claims="$(shard_claims "$WORKFLOW" guards-hooks)"
check "the hooks tail claims the name seam" "$hook_tail_expected" "$hook_tail_claims"
[[ -n "$hook_tail_claims" ]] && ok "the hooks tail claim set is non-empty" || bad "the hooks tail claims no suites"
check "the hooks shard claim sets are disjoint" "" \
  "$(comm -12 <(printf '%s\n' "$hook_tail_claims") <(printf '%s\n' "$hook_kept_claims"))"

# --- 3b. Must-fail: the ways this partition breaks --------------------------
# Each arm mutates a copy of the workflow, and the section above must name the
# damage. An arm that stays clean means the section reports nothing. An arm
# whose needle no longer matches the workflow leaves the copy unchanged and
# judges the workflow itself, so each copy must differ from what it mutates.
# Headings remain intact when a suite call becomes a no-op. Only calls
# received by the shim can establish the tail's ownership.
wf_hook_noop="$TMP/wf-hook-tail-noop.yml"
awk '
  index($0, "- name: lane-mail and reviewer suites") { tail = 1 }
  tail && substr($0, 1, 8) == "      - " && !index($0, "- name: lane-mail and reviewer suites") { tail = 0 }
  tail && /bash skills\/orch\/tests\/run-all.sh --battery/ { sub(/bash skills\/orch\/tests\/run-all.sh/, ":"); hits++ }
  { print }
  END { exit hits != 1 }
' "$WORKFLOW" > "$wf_hook_noop"
edited "$WORKFLOW" "$wf_hook_noop" hook-tail-noop
claims_file "$wf_hook_noop" "$TMP/claims-hook-noop"
check "must-fail: a tail with headings but no suite calls loses every moved suite" \
  "$hook_tail_expected" "$(comm -23 "$UNIV" <(sort -u "$TMP/claims-hook-noop"))"
check "must-fail: a tail with no suite calls has no shard claims" "" \
  "$(shard_claims "$wf_hook_noop" guards-hooks-tail)"

# Removing the tail step must return its suites to guards-hooks. Comments
# carrying either moved glob must not satisfy that fallback.
wf_no_hook_tail="$TMP/wf-hook-tail-deleted.yml"
awk '
  index($0, "- name: lane-mail and reviewer suites") { drop = 1; hits++; next }
  drop && substr($0, 1, 8) == "      - " { drop = 0 }
  drop { next }
  { print }
  END { exit hits != 1 }
' "$WORKFLOW" > "$wf_no_hook_tail"
edited "$WORKFLOW" "$wf_no_hook_tail" hook-tail-deleted
claims_file "$wf_no_hook_tail" "$TMP/claims-no-hook-tail"
check "deleting the hooks tail leaves no suite unclaimed" "" \
  "$(comm -23 "$UNIV" <(sort -u "$TMP/claims-no-hook-tail"))"
reclaimed="$(shard_claims "$wf_no_hook_tail" guards-hooks)"
check "deleting the hooks tail returns all its suites to guards-hooks" "$hook_tail_expected" \
  "$(comm -12 <(printf '%s\n' "$hook_tail_expected") <(printf '%s\n' "$reclaimed"))"

# Each glob is an independent claim rule. Keep it only in a comment, then
# remove the fallback's comment filter to prove the missing suites are named.
while IFS= read -r glob; do
  wf_hook_prose="$TMP/wf-hook-glob-comment.yml"
  awk -v glob="$glob" '
    index($0, "--suite-list hooks/tests/lane-mail-") { print "          # " glob }
    (i = index($0, glob " \\")) { $0 = substr($0, 1, i - 1) substr($0, i + length(glob) + 1); hits++ }
    (i = index($0, glob ")\"")) { $0 = substr($0, 1, i - 1) substr($0, i + length(glob)); hits++ }
    { print }
    END { exit hits != 1 }
  ' "$WORKFLOW" > "$wf_hook_prose"
  edited "$WORKFLOW" "$wf_hook_prose" "hook-glob-comment $glob"
  claims_file "$wf_hook_prose" "$TMP/claims-hook-prose"
  check "a hooks glob in a comment is reclaimed: $glob" "" \
    "$(comm -23 "$UNIV" <(sort -u "$TMP/claims-hook-prose"))"
  wf_hook_open="$TMP/wf-hook-comment-filter-removed.yml"
  awk '
    index($0, "- name: hook and moved commit-guards suites") { hook = 1 }
    hook && /claims="\$\(grep -v/ { print "          claims=\"$(cat \"$wf\")\""; hits++; hook = 0; next }
    { print }
    END { exit hits != 1 }
  ' "$wf_hook_prose" > "$wf_hook_open"
  edited "$wf_hook_prose" "$wf_hook_open" "hook-comment-filter-removed $glob"
  claims_file "$wf_hook_open" "$TMP/claims-hook-open"
  expected="$(cd "$ROOT" && printf '%s\n' $glob | sort)"
  check "must-fail: a prose-only hooks glob loses its named suites when comments count: $glob" \
    "$expected" "$(comm -23 "$UNIV" <(sort -u "$TMP/claims-hook-open"))"
done <<'GLOBS'
hooks/tests/lane-mail-*.test.sh
hooks/tests/reviewer-*.test.sh
GLOBS

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

# A moved path left only in a comment. The fallback in the step that globs the
# path's package reads run-block text, so it reclaims the suite and the
# partition holds; with that filter removed it reads the comment instead,
# skips the suite, and the suite runs in no shard. Each row is one arm: the
# first check says the fallback fires, the second says this section is what
# catches it when it does not. A row is `path|loop`, the moved path and the
# first line of the step's candidate list that spells it, above which the
# comment goes so the list's continuation lines stay whole.
prose_rows=0
while IFS='|' read -r moved loop; do
  prose_rows=$((prose_rows + 1))
  wf_prose="$TMP/wf-path-in-comment-$prose_rows.yml"
  awk -v moved="$moved" -v loop="$loop" '
    index($0, loop) { print "          # " moved; hits++ }
    (i = index($0, moved " \\")) { $0 = substr($0, 1, i - 1) substr($0, i + length(moved) + 1); cut++ }
    (i = index($0, moved ")\"")) { $0 = substr($0, 1, i - 1) substr($0, i + length(moved)); cut++ }
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
skills/commit-guards/tests/install-git-hooks.test.sh|--suite-list hooks/tests/*.sh
tools/tests/harness-smoke.test.sh|--suite-list tools/tests/harness-smoke.test.sh
skills/commit-guards/tests/md-refs.test.sh|--suite-list skills/commit-guards/tests/pre-push.test.sh
ROWS

# The step that globs a package, deleted. `rest` skips a package only where
# this file still runs it, and the needle it looks for is the owning loop's
# glob, which leaves with that loop; the package's suites come back here
# instead of going nowhere. The two paths the hooks shards spell stay, so they
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

for package in slack review-gate jarvis; do
  wf_owner_removed="$CONTROL_TMP/wf-owner-removed-$package.yml"
  claims_file "$wf_owner_removed" "$TMP/claims-owner-removed-$package"
  check "$package suites move to rest when dedicated ownership is removed" \
    "$(grep "^skills/$package/tests/" "$UNIV")" \
    "$(grep "^skills/$package/tests/" "$TMP/claims-owner-removed-$package")"
done

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

# Compare the workflow's executed claims with the selector's package routing.
declared_shards="$(sed -n "s/^ \{8\}shard: .*'\[\(.*\)\]'.*\$/\1/p" "$WORKFLOW" |
  tr -d ' "' | tr ',' '\n' | sort -u)"
if [[ -z "$declared_shards" ]]; then
  bad "no shard list in $WORKFLOW, so no citation can be judged against it"
fi

JOB_SET="$ROOT/tools/ci-job-set"

suite_owners() { # <workflow> [files [bash-major]] ; `shard<tab>path`, by directory or every file
  local wf="$1" mode="${2-directories}" major="${3-}" dir="$TMP/owner-blocks" f shard cond wd run word
  local PARTITION_RUNNER_OS=Linux PARTITION_NATIVE=false os=ubuntu-latest excluded native="" out="$TMP/owner-step.out"
  [[ "$major" != 3 ]] || { PARTITION_RUNNER_OS=macOS; PARTITION_NATIVE=true; os=macos-latest; native="$POOL/tools/macos-test-contracts"; }
  excluded="$(excluded_shards "$wf" "$os")"
  cp "$wf" "$PART/.github/workflows/skill-tests.yml"
  split_run_blocks "$wf" "$dir"
  {
    for f in "$dir"/*.sh; do
      roster_block "$f" || continue
      shard="$(one_shard "$(cat "${f%.sh}.cond")")"
      [[ -n "$shard" ]] || continue
      [[ -z "${PARTITION_ONLY_SHARD:-}" || "$shard" == "$PARTITION_ONLY_SHARD" ]] || continue
      grep -qxF "$shard" <<< "$excluded" && continue
      # The runner names its platform in RUNNER_OS, and run-all.sh's shard_of
      # reads it.
      if ! RUNNER_OS="$PARTITION_RUNNER_OS" RUN_ALL_NATIVE_CONTRACTS="$native" run_roster_step "$f" > "$out" 2>&1; then
        printf 'partition-step: shard=%s block=%s result=failed\n' "$shard" "$f" >&2
        cat "$out" >&2
        return 1
      fi
      sed -n "s%^suite-invoked: %$shard	%p" "$out"
    done
    # One-line steps: the package a node step works in, or the first word of
    # its `run:` that names a file in this tree.
    one_line_steps "$wf" | while IFS=$'\037' read -r _ cond wd run; do
      shard="$(one_shard "$cond")"
      [[ -n "$shard" ]] || continue
      [[ -z "${PARTITION_ONLY_SHARD:-}" || "$shard" == "$PARTITION_ONLY_SHARD" ]] || continue
      grep -qxF "$shard" <<< "$excluded" && continue
      [[ "$run" != 'bash skills/orch/tests/run-all.sh --battery '* ]] || continue
      [[ "$run" != 'bash skills/orch/tests/run-all.sh --report-job' ]] || continue
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

# The migrated steps retain the same claim reader. Each table row supplies a
# required suite independent of the selector arrays built by the workflow.
# Missing and repeated calls must name that suite, and an assertion failure
# must cross the real pool runner and the workflow block's exit status.
while IFS='|' read -r shard step battery stem; do
  path="$battery/$stem.sh"
  grep -qxF "$path" "$UNIV" || [[ "$battery" == skills/linear/tests ]] ||
    { bad "pooled control names no suite: $path"; continue; }

  bad_pool="$TMP/assertion-pool"
  rm -rf -- "${bad_pool:?}"
  cp -R "$POOL" "$bad_pool"
  printf '#!/usr/bin/env bash\ntest green = red\n' > "$bad_pool/$path"
  bad_cache="$TMP/assertion-claims"
  rm -rf -- "${bad_cache:?}"
  mkdir -p "$bad_cache"
  split_run_blocks "$WORKFLOW" "$TMP/assertion-blocks"
  cp "$WORKFLOW" "$PART/.github/workflows/skill-tests.yml"
  result=not-run
  for block in "$TMP/assertion-blocks"/*.sh; do
    [[ "$(one_shard "$(cat "${block%.sh}.cond")")" == "$shard" ]] || continue
    if [[ "$battery" == skills/github/tests ]]; then
      grep -qF 'for dir in skills/*/tests' "$block" || continue
    else
      grep -qE -- "--battery $battery([[:space:]]|\)|$)" "$block" || continue
    fi
    rc=0
    PARTITION_POOL="$bad_pool" PARTITION_POOL_CLAIMS="$bad_cache" \
      run_roster_step "$block" > "$TMP/assertion-step.log" 2>&1 || rc=$?
    tree="${battery%/tests}"; tree="${tree##*/}"
    if [[ "$rc" -ne 0 ]] && grep -qxF -e "  - $stem" -e "  - $tree--$stem" -- "$bad_cache"/*.out; then
      result=failed
      break
    fi
  done
  check "must-fail: a pooled assertion fails its owning step: $step $battery" failed "$result"
done <<< "$POOLED_ROWS"

owner_selection() { # <ci-job-set> <repository> <field> <shard> <path> <out> ; missed `shard<tab>path`
  local job_set="$1" repository="$2" field="$3" shard="$4" path="$5" out="$6" selected
  : > "$out"
  ( cd "$repository" && CHANGE_CLASS=micro DOCS_ONLY=false CHANGED_PATHS="$path" EVENT=pull_request \
    GITHUB_OUTPUT="$out" "$job_set" --event-parity ) 2>/dev/null ||
    { printf '%s\t%s\tci-job-set-failed\n' "$shard" "$path"; return; }
  selected="$(cat "$out")" || return 1
  [[ -z "$field" ]] || selected="$(sed -n "s/^$field=//p" "$out")" || return 1
  grep -qF "\"$shard\"" <<< "$selected" || printf '%s\t%s\n' "$shard" "$path"
}

unselected_owners() { # <ci-job-set> <owners file> <repository> <field>
  local shard path
  while IFS=$'\t' read -r shard path; do
    owner_selection "$1" "$3" "$4" "$shard" "$path" "$TMP/owner-selection" ||
      printf '%s\t%s\towner-row-unread\n' "$shard" "$path"
  done < "$2"
}

unmapped_owners() { # <ci-job-set> <owners file> ; missed shard and path
  local selector="$1" owners="$2" shard path selected
  while IFS=$'\t' read -r shard path; do
    # The scan steps are selected by changed tree, not by suite ownership.
    [[ "$shard" != guards-scans ]] || continue
    if ! selected="$(cd "$ROOT" && "$selector" --suite-shards "$path")"; then
      printf '%s\t%s\tci-job-set-failed\n' "$shard" "$path"
    elif [[ " $selected " != *" $shard "* ]]; then
      printf '%s\t%s\n' "$shard" "$path"
    fi
  done < "$owners"
}

check "must-fail: a tail with no suite calls has no selection owners" "" \
  "$(suite_owners "$wf_hook_noop" | awk -F '\t' '$1 == "guards-hooks-tail" { print $2 }')"

# run-all.sh refuses a shard that shard_of gives no suite, so an orch leg the
# macOS roster keeps for such a shard fails every run that selects orch. § 4c
# holds the queue's macOS legs to the same exclusions.
check "each orch shard a macOS leg runs owns a suite under RUNNER_OS=macOS" "" \
  "$(comm -23 <(sed -n "s/^        shard: &skill-suite-shards .*'\[\([^]]*\)\]'.*/\1/p" "$WORKFLOW" | tr -d ' "' | tr ',' '\n' | grep '^orch-' | sort -u) \
      <(excluded_shards "$WORKFLOW" macos-latest | sort -u) |
    while IFS= read -r shard; do
      [[ -n "$(PARTITION_RUNNER_OS=macOS selected --shard "$shard")" ]] || printf '%s\n' "$shard"
    done)"

OWNERS="$TMP/owners"
{ suite_owners "$WORKFLOW"; suite_owners "$WORKFLOW" directories 3; } | sort -u > "$OWNERS"
owner_shards="$(cut -f1 "$OWNERS" | sort -u)"
check "a suite is read for every shard the matrix declares" "$declared_shards" "$owner_shards"
check "ci-job-set maps each suite package to the shard running it" \
  "" "$(unmapped_owners "$JOB_SET" "$OWNERS")"

# Workflow claims and dependency searches are separate evidence. A
# minimal repository prevents orch's GitHub dependency from hiding a broken
# direct package mapping in the selector control.
for major in 4 3; do
  suite_owners "$WORKFLOW" files "$major" > "$TMP/github-platform-owners"
  grep '^skills/github/tests/' "$UNIV" > "$TMP/github-expected"
  if [[ "$major" == 3 ]]; then
    "$ROOT/tools/macos-test-contracts" --filter <"$TMP/github-expected" >"$TMP/github-native-expected" || exit 1
    mv "$TMP/github-native-expected" "$TMP/github-expected"
  fi
  check "GitHub suites belong only to rest under Bash $major" \
    "$(sed 's%^%rest\t%' "$TMP/github-expected")" \
    "$(awk -F '\t' '$2 ~ /^skills\/github\/tests\// {print}' "$TMP/github-platform-owners" | sort)"
done
GITHUB_SELECT="$(mktemp -d)" || { bad "GitHub selector scratch allocation failed"; exit 1; }
[[ -d "$GITHUB_SELECT" && ! -L "$GITHUB_SELECT" ]] || exit 1
GITHUB_SELECT="$(cd -- "$GITHUB_SELECT" && pwd -P)"
trap 'rm -rf -- "${baseline_tmp:?}" "${CONTROL_TMP:?}" "${GITHUB_SELECT:?}"' EXIT
mkdir -p "$GITHUB_SELECT/tools/lib" "$GITHUB_SELECT/skills/github/tests"
cp "$PART/tools/rust-reads" "$GITHUB_SELECT/tools/rust-reads"
cp "$ROOT/tools/lib/skill-requirements.awk" "$GITHUB_SELECT/tools/lib/skill-requirements.awk"
cp "$JOB_SET" "$GITHUB_SELECT/tools/ci-job-set"
# The selector projects the reach tools/guard derives beside it.
cp "$ROOT/tools/guard" "$GITHUB_SELECT/tools/guard"
cp "$ROOT/tools/macos-test-contracts" "$ROOT/tools/macos-test-contracts.json" "$GITHUB_SELECT/tools/"
stub_suite "$GITHUB_SELECT/skills/github/tests/pr-view.test.sh"
git -C "$GITHUB_SELECT" init -q
git -C "$GITHUB_SELECT" add skills/github/tests/pr-view.test.sh
github_selection() {
  ( cd "$GITHUB_SELECT" && CHANGE_CLASS=micro DOCS_ONLY=false \
    CHANGED_PATHS=skills/github/tests/pr-view.test.sh EVENT=merge_group \
    GITHUB_OUTPUT="$TMP/github-selection" tools/ci-job-set ) >&2 || return
  sed -n 's/^shards=//p' "$TMP/github-selection"
}
check "a direct GitHub suite selects its owner on a merge group" '["guards-scans","rest"]' "$(github_selection)"
awk '$0 == "    skills/github) want_shard rest ;;" {
       $0 = "    skills/github) want_shard mailbox ;;"; n++
     } {print} END {exit n != 1}' "$JOB_SET" > "$GITHUB_SELECT/tools/ci-job-set" ||
  { bad "GitHub mapping control changed other than one row"; exit 1; }
: > "$TMP/github-selection"
check "must-fail: routing GitHub away from rest selects the wrong shard" \
  '["guards-scans","mailbox"]' "$(github_selection)"

# --- 4c. The nightly macOS matrix's exclusions --------------------------
# The selector uses these exclusions for its macOS runner arithmetic.
# .github/workflows/skill-tests.yml owns execution policy: its nightly
# macOS job uses the full fallback roster and applies these exclusions.

# The shards the nightly macOS matrix excludes, read as
# YAML sequence items the way cargo_excluded_legs reads them.
macos_excluded_shards() { # macos_excluded_shards <workflow>
  excluded_shards "$1" macos-latest
}
linux_only_shards() { # linux_only_shards <ci-job-set>
  "$ROOT/tools/macos-test-contracts" --linux-only-shards | tr ' ' '\n' | grep . | sort -u
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

# The queue fallback names the full roster less the native exclusions.
queue_fallback_shards() { # queue_fallback_shards <workflow>
  awk '/^  [A-Za-z0-9_-]+:/ { job = $1 }
       job == "skill-suites-macos-queue:" && /^        shard: / { print }' "$1" |
    sed -n "s/.*'\(\[[^]]*\]\)'.*/\1/p" | tr -d '[]" ' | tr ',' '\n' | grep . | sort -u
}
queue_shards="$(queue_fallback_shards "$WORKFLOW")"
grep -qx rest <<< "$queue_shards" ||
  bad "no queue shard read from $WORKFLOW, so the queue reader is broken"
check "the queue fallback equals the nightly roster less its macOS exclusions" \
  "$(comm -23 <(sed -n "s/^        shard: &skill-suite-shards .*'\[\([^]]*\)\]'.*/\1/p" "$WORKFLOW" | tr -d ' "' | tr ',' '\n' | sort -u) <(printf '%s\n' "$excluded"))" "$queue_shards"
check "no queue macOS shard is Linux-only" "" \
  "$(comm -12 <(printf '%s\n' "$queue_shards") <(linux_only_shards "$JOB_SET"))"
sed "s/'\[\"review-gate\", /'[\"linear-controls\", \"review-gate\", /" "$WORKFLOW" > "$TMP/queue-linux.yml"
cmp -s "$WORKFLOW" "$TMP/queue-linux.yml" &&
  bad "must-fail: the queue fallback list is no longer one line in $WORKFLOW"
check "must-fail: a queue fallback naming a Linux-only shard is named" "linear-controls" \
  "$(comm -12 <(queue_fallback_shards "$TMP/queue-linux.yml") <(linux_only_shards "$JOB_SET"))"

# --- 4d. Exactly-once suite coverage on each original shell runner --------
# Linux runs every shell suite. The native eligibility owner defines the
# macOS subset. Actual workflow discovery must cover each eligible file once.
# The roster jobs are the Linux job and the nightly macOS job; the merge
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
  bad "must-fail: the nightly macOS os line is no longer one line in $WORKFLOW"
check "must-fail: a nightly roster moved off macOS loses its OS" \
  $'ubuntu-latest\nubuntu-latest' "$(roster_os "$TMP/mac-roster-linux.yml")"
shared_steps() { # WORKFLOW — the Linux anchor and macOS alias
  awk '
    /^  [A-Za-z0-9_-]+:/ { job = $1 }
    /^    steps:/ && (job == "skill-suites-shard:" || job == "skill-suites-macos:" || job == "skill-suites-macos-queue:" || job == "skill-suites-main-only:") { print job " " $2 }
  ' "$1"
}
# The final timing measurement belongs to the shared job, after every
# selected battery, rather than to any individual battery completion.
job_report_boundary() { # WORKFLOW — count, success condition and final step
  local records last
  records="$(one_line_steps "$1" | awk -F '\037' '$1 == "skill-suites-shard" && $4 == "bash skills/orch/tests/run-all.sh --report-job" {n++; cond=$2} END {printf "%d|%s",n+0,cond}')"
  last="$(awk '
    /^  [A-Za-z0-9_-]+:/ { job=$1 }
    job == "skill-suites-shard:" && substr($0,1,8) == "      - " {step=NR}
    job == "skill-suites-shard:" && $0 == "        run: bash skills/orch/tests/run-all.sh --report-job" {report=NR}
    END {print (report > step ? "last" : "not-last")}
  ' "$1")"
  printf '%s|%s' "$records" "$last"
}
check 'one successful final job report follows every selected battery' \
  '1|success()|last' "$(job_report_boundary "$WORKFLOW")"
for rule in missing duplicated early failed; do
  case "$rule" in
    missing) sed '/run: bash skills\/orch\/tests\/run-all.sh --report-job/d' "$WORKFLOW" >"$TMP/job-$rule.yml" ;;
    duplicated) awk '{print} /        run: bash skills\/orch\/tests\/run-all.sh --report-job/ {print "      - name: Duplicate job report"; print "        if: success()"; print}' "$WORKFLOW" >"$TMP/job-$rule.yml" ;;
    early) sed '/run: bash skills\/orch\/tests\/run-all.sh --report-job/a\
      - run: echo later-job-work' "$WORKFLOW" >"$TMP/job-$rule.yml" ;;
    failed) sed '/if: success()/s/success()/always()/' "$WORKFLOW" >"$TMP/job-$rule.yml" ;;
  esac
  case "$rule" in
    missing) want='0||not-last' ;;
    duplicated) want='2|success()|last' ;;
    early) want='1|success()|not-last' ;;
    failed) want='1|always()|last' ;;
  esac
  check "must-fail: $rule final-job boundary changes the producer contract" \
    "$want" "$(job_report_boundary "$TMP/job-$rule.yml")"
done
sed 's/steps: \*skill-suite-steps/steps: []/' "$WORKFLOW" > "$TMP/mac-empty.yml"

os_claims() { # <workflow> <os> <major> ; suite files the expanded matrix runs
  local wf="$1" os="$2" major="$3" excluded="" owners="$TMP/os-owners"
  if [[ "$os" == macos-latest ]]; then
    excluded="$(macos_excluded_shards "$wf" | tr '\n' ' ')" || return
  fi
  suite_owners "$wf" files "$major" > "$owners" || return
  awk -F '\t' -v excluded="$excluded" '
    BEGIN { n = split(excluded, names, " "); for (i = 1; i <= n; i++) skip[names[i]] = 1 }
    NR == FNR { universe[$0] = 1; next }
    !skip[$1] && $2 in universe { print $2 }
  ' "$TMP/os-universe" "$owners" | sort
}

# Read the actual job conditions and matrix before executing their suite steps.
# shellcheck source=../../skills/harness-ci/tests/lib/workflow.sh
. "$ROOT/skills/harness-ci/tests/lib/workflow.sh"

suite_env() { # WORKFLOW CONTEXT FIELD
  local expr
  expr="$(sed -n "/^      $3: / { s/^      $3: //; s/^[$]{{ //; s/ }}$//; p; }" "$1")" || return
  [[ -n "$expr" ]] || return 1
  gh_eval value "$2" "$expr" | jq -er 'select(type == "string")'
}

event_claims() { # WORKFLOW EVENT OS MAJOR ; actual job/matrix/environment claims
  local wf="$1" event="$2" os="$3" major="$4" result=skipped ref=refs/heads/main ctx job needs expr running axes shards excluded job_shards step_routes matrix row_ctx temporal_ctx filters temporary shard declarations claims="$TMP/event-dedicated"
  [[ "$event" != merge_group ]] || { result=failure; ref=refs/heads/gh-readonly-queue/main/fixture; }
  # A failed changes job exercises the workflow's full fallback: the
  # required roster on a merge group, and on a main push the roster a
  # failed same-head proof read runs. tools/tests/ci-class-job-set-events
  # holds the proved complement.
  [[ "$event" != push ]] || result=failure
  step_routes="$(shared_steps "$wf")" || return
  published_map "$wf" > "$TMP/event-map" || return
  ctx="$(context_json "$event" "$result" '' "$TMP/event-map" "$ref")" || return
  job_ifs "$wf" > "$TMP/event-job-ifs" || return
  job_needs "$wf" > "$TMP/event-job-needs" || return
  {
    while IFS=$'\t' read -r job expr; do
      case "$job" in skill-suites-shard|skill-suites-macos|skill-suites-macos-queue|skill-suites-main-only) ;; *) continue ;; esac
      needs="$(awk -F '\t' -v job="$job" '$1 == job { print $2 }' "$TMP/event-job-needs")" || return
      running="$(printf '%s\t%s\t%s\n' "$job" "$needs" "$expr" | gh_eval jobs "$ctx")" || return
      case "$running" in '') continue ;; "$job") ;; *) return 1 ;; esac
      grep -Fxq -- "$job: *skill-suite-steps" <<< "$step_routes" ||
        grep -Fxq -- "$job: &skill-suite-steps" <<< "$step_routes" || continue
      if [[ "$job" == skill-suites-main-only ]]; then
        expr="$(matrix_expr "$wf" include "$job")" || return
        matrix="$(gh_eval value "$ctx" "$expr")" || return
        declarations="$(jq -c --arg os "$os" '.[] | select(.os == $os)' <<< "$matrix")" || return
        while IFS= read -r row_ctx; do
          [[ -n "$row_ctx" ]] || continue
          temporal_ctx="$(jq -c --argjson matrix "$row_ctx" '.matrix = $matrix' <<< "$ctx")" || return
          temporary="$(suite_env "$wf" "$temporal_ctx" TEMPORARY_SUITE)" || return
          filters="$(suite_env "$wf" "$temporal_ctx" MAIN_ONLY_FILTERS)" || return
          shard="$(jq -er '.shard' <<< "$row_ctx")" || return
          TEMPORARY_SUITE="$temporary" MAIN_ONLY_FILTERS="$filters" PARTITION_ONLY_SHARD="$shard" \
            suite_owners "$wf" files "$major" > "$claims" || return
          if [[ ! -s "$claims" ]]; then
            printf 'partition-dedicated: suite=%s os=%s selection=empty\n' "$temporary" "$os" >&2
            return 1
          fi
          cat "$claims"
        done <<< "$declarations"
        continue
      fi
      expr="$(matrix_expr "$wf" os "$job")" || return
      [[ -n "$expr" ]] || return 1
      axes="$(gh_eval value "$ctx" "$expr" | jq -r --arg os "$os" 'if type == "array" then index($os) != null else error("matrix-os-not-array") end')" || return
      [[ "$axes" == true ]] || continue
      expr="$(matrix_expr "$wf" shard "$job")" || return
      [[ -n "$expr" ]] || return 1
      shards="$(gh_eval value "$ctx" "$expr" | jq -er 'select(type == "array" and length > 0) | .[]')" || return
      excluded="$(excluded_shards "$wf" "$os")" || return
      job_shards="$(grep -xvF -f <(printf '%s\n' "$excluded") <<<"$shards")"
      [[ -n "$job_shards" ]] || continue
      # Only the refresh block reads the remaining exception. Its ordinary
      # matrix row has a shard and runner, and carries no suite override.
      filters=''
      if grep -qxF refresh <<< "$job_shards"; then
        row_ctx="$(jq -c --arg os "$os" '.matrix = {shard: "refresh", os: $os}' <<< "$ctx")" || return
        filters="$(suite_env "$wf" "$row_ctx" MAIN_ONLY_FILTERS)" || return
      fi
      MAIN_ONLY_FILTERS="$filters" suite_owners "$wf" files "$major" |
        awk -F '\t' -v shards="$job_shards" '
          BEGIN { n = split(shards, names, "\n"); for (i = 1; i <= n; i++) count[names[i]]++ }
          { for (i = 0; i < count[$1]; i++) print }
        ' || return
    done < "$TMP/event-job-ifs"
  } | awk -F '\t' '
    NR == FNR { universe[$0] = 1; next }
    $2 in universe { print $2 }
  ' "$TMP/os-universe" - | sort
}

awk '$0 == "            case \"$t\" in skills/linear/tests/must-fail-controls.sh) continue ;; esac" {
       sub(/continue/, ":"); n++
     }
     { print } END { exit n != 1 }' "$WORKFLOW" > "$TMP/linear-unskipped.yml" ||
  bad "must-fail: the linear loop skip is no longer one line in the workflow"

for os in ubuntu-latest macos-latest; do
  major=4
  [[ "$os" != macos-latest ]] || major=3
  cp "$UNIV" "$TMP/os-universe"
  for f in "$ROOT"/skills/linear/tests/*.sh; do
    printf '%s\n' "${f#"$ROOT/"}" >> "$TMP/os-universe"
  done
  sort -o "$TMP/os-universe" "$TMP/os-universe"
  if [[ "$os" == macos-latest ]]; then
    "$ROOT/tools/macos-test-contracts" --filter <"$TMP/os-universe" >"$TMP/native-universe" || exit 1
    mv "$TMP/native-universe" "$TMP/os-universe"
  fi
  [[ -s "$TMP/os-universe" ]] || { bad "the suite discovery is empty for $os"; continue; }
  printf 'coverage: os=%s suites=%s\n' "$os" "$(wc -l < "$TMP/os-universe" | tr -d ' ')"
  for event in merge_group push schedule workflow_dispatch; do
    event_claims "$WORKFLOW" "$event" "$os" "$major" > "$TMP/event-claims" ||
      { bad "event claims could not evaluate $event on $os"; continue; }
    expected="$(cat "$TMP/os-universe")"
    if [[ "$os" == ubuntu-latest ]]; then
      case "$event" in
        merge_group) expected="$(grep -xvF refresh/tests/adopt-refresh.test.sh "$TMP/os-universe")" ;;
        push) ;;
        *) expected='' ;;
      esac
    fi
    check "$event covers its eligible shell roster exactly once on $os" \
      "$expected" "$(cat "$TMP/event-claims")"
  done
  if [[ "$os" == ubuntu-latest ]]; then
    event_claims "$TMP/linear-unskipped.yml" merge_group "$os" "$major" > "$TMP/linear-unskipped"
    check "must-fail: the required Linux roster names a repeated suite" \
      skills/linear/tests/must-fail-controls.sh "$(uniq -d "$TMP/linear-unskipped")"
  else
    event_claims "$TMP/mac-empty.yml" merge_group "$os" "$major" > "$TMP/event-omission"
    check "must-fail: a merge-group job with no native steps loses the native roster" \
      "$(cat "$TMP/os-universe")" "$(comm -23 "$TMP/os-universe" "$TMP/event-omission")"
  fi
done

# --- 4e. The checkout kendex on each Linux leg ----------------------------
# A suite tools/ci-job-set gives the checkout kendex on Linux skips its
# real-kendex rows where its leg built none, and the leg reads green. Every
# Linux shard running such a suite must be one the `kendex from this checkout`
# step builds for, read from that step's real `if:`.
kendex_build_if() { # WORKFLOW ; the `if:` text of the kendex build step
  awk 'build && /^        if: / { sub(/^        if: /, ""); print; exit }
       /^      - / { build = ($0 == "      - name: kendex from this checkout") }' "$1"
}
unbuilt_checkout_legs() { # WORKFLOW ; each checkout shard whose Linux leg builds no kendex
  local cond shard built
  cond="$(kendex_build_if "$1")"
  [[ -n "$cond" ]] || { printf 'no-build-condition\n'; return 0; }
  for shard in $(cut -f1 "$TMP/checkout-suites" | sort -u); do
    built="$(gh_eval value "$(jq -cn --arg shard "$shard" '{matrix: {shard: $shard}, runner: {os: "Linux"}}')" "$cond")"
    [[ "$built" == true ]] || printf '%s\n' "$shard"
  done
}
suite_owners "$WORKFLOW" > "$TMP/kendex-owners"
: > "$TMP/checkout-suites"
while IFS=$'\t' read -r shard path; do
  policy="$(cd "$ROOT" && "$JOB_SET" --suite-kendex Linux "$path" "$shard")" ||
    { bad "ci-job-set gave no kendex policy for $path"; continue; }
  [[ "$policy" != checkout ]] || printf '%s\t%s\n' "$shard" "$path" >> "$TMP/checkout-suites"
done < "$TMP/kendex-owners"
check "the checkout-kendex legs read from ci-job-set include jarvis, orch-rest, refresh and rest" "" \
  "$(comm -23 <(printf '%s\n' jarvis orch-rest refresh rest) <(cut -f1 "$TMP/checkout-suites" | sort -u))"
check "every Linux leg running a checkout-kendex suite builds kendex from this checkout" "" \
  "$(unbuilt_checkout_legs "$WORKFLOW")"
plant "$WORKFLOW" " || matrix.shard == 'jarvis') && runner.os == 'Linux'" ") && runner.os == 'Linux'" \
  "$TMP/kendex-unbuilt.yml" "skill-suites-shard/kendex from this checkout"
check "must-fail: a build step dropping jarvis names the leg whose picker rows would skip" jarvis \
  "$(unbuilt_checkout_legs "$TMP/kendex-unbuilt.yml")"

# --- 4f. The package runtimes on each leg whose suites run them ------------
# orch-runtime's wrapper builds at its first call where no build matches the
# checkout, and the orch package's scripts, the hook, the mailbox's
# lane-mail.sh, lane-mail-compact.sh and lane-mail-session.sh,
# second-opinion's room-check.test.sh and Jarvis's presence.test.sh (the
# hook's world) and its forward, owner-unanswered and watch-loop suites
# (`lane-mail compact`), and Slack's mailbox-read.test.sh and notice.test.sh
# (`lane-mail compact` too), tools' guard-selection and validation-routing
# (`orch-runtime validate entry`) and Jarvis's session, succession, task,
# controls, succession-controls and owner-note suites run it, and so do the
# worktree suites whose reuse or restack reads `validate entry --live`, so a leg
# owning one of those suites on either
# runner builds both runtimes first, read from that step's real `if:`. The runtimes' own Rust targets run in one step, the
# orch-rest Linux leg's, wherever the changes job's `rust_targets` list is
# not empty.
step_if() { # WORKFLOW STEP ; that step's `if:` text, its `${{ }}` stripped
  awk -v name="      - name: $2" '
    found && /^        if: / {
      sub(/^        if: /, "")
      if (substr($0, 1, 3) == "${{") { $0 = substr($0, 4); sub(/}}[ ]*$/, "") }
      print; exit
    }
    /^      - / { found = ($0 == name) }' "$1"
}
RUNTIME_STEP="the package runtimes, built"
unbuilt_runtime_legs() { # WORKFLOW OS SUITES ; `OS shard` for each shard of SUITES whose leg on OS builds no runtime
  local cond shard
  cond="$(step_if "$1" "$RUNTIME_STEP")"
  [[ -n "$cond" ]] || { printf 'no-build-condition\n'; return 0; }
  for shard in $(cut -f1 "$3" | sort -u); do
    [[ "$(gh_eval value "$(jq -cn --arg shard "$shard" --arg os "$2" '{matrix: {shard: $shard}, runner: {os: $os}}')" "$cond")" == true ]] ||
      printf '%s %s\n' "$2" "$shard"
  done
}
runtime_suites() { # OWNERS OUT ; the `shard<tab>path` rows of OWNERS whose suite runs orch-runtime
  local shard path
  : > "$2"
  while IFS=$'\t' read -r shard path; do
    case "$path" in
      skills/orch/tests/* | hooks/tests/* | skills/second-opinion/tests/room-check.test.sh | \
      skills/mailbox/tests/lane-mail-session.sh | skills/mailbox/tests/lane-mail.sh | skills/mailbox/tests/lane-mail-compact.sh | \
      skills/jarvis/tests/presence.test.sh | skills/jarvis/tests/forward.test.sh | \
      skills/jarvis/tests/owner-unanswered.test.sh | skills/jarvis/tests/watch-loop.test.sh | \
      skills/slack/tests/mailbox-read.test.sh | skills/slack/tests/notice.test.sh | \
      tools/tests/guard-selection.test.sh | tools/tests/validation-routing.test.sh | \
      skills/jarvis/tests/session.test.sh | skills/jarvis/tests/succession.test.sh | skills/jarvis/tests/task.test.sh | \
      skills/jarvis/tests/controls.test.sh | skills/jarvis/tests/succession-controls.test.sh | skills/jarvis/tests/owner-note.test.sh | \
      skills/worktree/tests/worktree_base_dir.sh | skills/worktree/tests/worktree_create_active_guard.sh | \
      skills/worktree/tests/worktree_create_restack.sh | skills/worktree/tests/worktree_default_branch.sh | \
      skills/worktree/tests/worktree_no_worktree_installs.sh | skills/worktree/tests/worktree_push_rebase.sh | \
      skills/worktree/tests/worktree_restack_hook_hold.sh | skills/worktree/tests/worktree_restack_replay.sh | \
      skills/worktree/tests/worktree_reuse_dropped_links.sh | skills/worktree/tests/worktree_session_guard_lifecycle.sh | \
      skills/worktree/tests/worktree_symlink_shadows_tracked.sh)
        printf '%s\t%s\n' "$shard" "$path" >> "$2" ;;
    esac
  done < "$1"
}
suite_owners "$WORKFLOW" files > "$TMP/runtime-owners"
suite_owners "$WORKFLOW" files 3 > "$TMP/runtime-owners-macos"
runtime_suites "$TMP/runtime-owners" "$TMP/runtime-suites"
runtime_suites "$TMP/runtime-owners-macos" "$TMP/runtime-suites-macos"
check "the Linux legs owning a suite that runs orch-runtime are the two orch legs, both hook legs, guards-tools, jarvis, mailbox, rest, slack and both worktree legs" \
  "$(printf '%s\n' guards-hooks guards-hooks-tail guards-tools jarvis mailbox orch-rest orch-state rest slack worktree worktree-restack)" \
  "$(cut -f1 "$TMP/runtime-suites" | sort -u)"
check "the macOS legs owning a suite that runs orch-runtime are both orch legs, both hook legs, guards-tools, rest, slack and worktree" \
  "$(printf '%s\n' guards-hooks guards-hooks-tail guards-tools orch-rest orch-state rest slack worktree)" \
  "$(cut -f1 "$TMP/runtime-suites-macos" | sort -u)"
check "every leg owning a suite that runs orch-runtime builds the package runtimes first" "" \
  "$(unbuilt_runtime_legs "$WORKFLOW" Linux "$TMP/runtime-suites"; unbuilt_runtime_legs "$WORKFLOW" macOS "$TMP/runtime-suites-macos")"
plant "$WORKFLOW" " || matrix.shard == 'guards-hooks-tail'" "" \
  "$TMP/runtime-unbuilt.yml" "skill-suites-shard/$RUNTIME_STEP"
check "must-fail: a build step dropping guards-hooks-tail names the leg whose hook suites would refuse" "Linux guards-hooks-tail" \
  "$(unbuilt_runtime_legs "$TMP/runtime-unbuilt.yml" Linux "$TMP/runtime-suites")"
plant "$WORKFLOW" " || matrix.shard == 'guards-tools'" "" \
  "$TMP/runtime-tools-unbuilt.yml" "skill-suites-shard/$RUNTIME_STEP"
check "must-fail: a build step dropping guards-tools names both legs whose guard-selection suite would refuse" \
  "$(printf '%s\n' 'Linux guards-tools' 'macOS guards-tools')" \
  "$(unbuilt_runtime_legs "$TMP/runtime-tools-unbuilt.yml" Linux "$TMP/runtime-suites"; unbuilt_runtime_legs "$TMP/runtime-tools-unbuilt.yml" macOS "$TMP/runtime-suites-macos")"
plant "$WORKFLOW" " || matrix.shard == 'rest' || matrix.shard == 'jarvis'" " || (matrix.shard == 'rest' && runner.os == 'Linux') || matrix.shard == 'jarvis'" \
  "$TMP/runtime-rest-linux.yml" "skill-suites-shard/$RUNTIME_STEP"
check "must-fail: a build step keeping rest to Linux names the macOS leg whose presence suite would refuse" "macOS rest" \
  "$(unbuilt_runtime_legs "$TMP/runtime-rest-linux.yml" macOS "$TMP/runtime-suites-macos")"
printf '%s\t%s\n' review-gate skills/jarvis/tests/controls.test.sh linear skills/jarvis/tests/succession-controls.test.sh \
  pi-claude-bridge skills/jarvis/tests/owner-note.test.sh > "$TMP/runtime-jarvis-owners"
runtime_suites "$TMP/runtime-jarvis-owners" "$TMP/runtime-jarvis-suites"
check "must-fail: Jarvis's controls, succession-controls and owner-note suites on legs that build nothing name each leg" \
  "$(printf '%s\n' 'Linux linear' 'Linux pi-claude-bridge' 'Linux review-gate')" \
  "$(unbuilt_runtime_legs "$WORKFLOW" Linux "$TMP/runtime-jarvis-suites")"
# The run block of one step, split under DIR, found by its `if:` text.
step_block() { # WORKFLOW STEP DIR ; that block's path, or `no-step` / `two-steps` and status 1
  local cond block="" f
  cond="\${{$(step_if "$1" "$2")}}"
  split_run_blocks "$1" "$3"
  for f in "$3"/*.cond; do
    [[ "$(cat "$f")" != "$cond" ]] || { [[ -z "$block" ]] || { printf 'two-steps\n'; return 1; }; block="${f%.cond}.sh"; }
  done
  [[ -n "$block" ]] || { printf 'no-step\n'; return 1; }
  printf '%s\n' "$block"
}
# The selection step both the lockfile check and the targets step read, run
# in DIR/work over RUST_TARGETS as the changes job published it, its step
# outputs left in DIR/selection.out for the step under test to take as its
# env. The tree holds a third runtime beside both shipped ones, which a
# fallback that discovers no runtime from the tree leaves out, and a skill
# with no runtime, which discovery must leave out.
SELECTION_STEP="the package runtimes the reach selects"
runtime_selection() { # WORKFLOW RUST_TARGETS DIR ; nothing, or the refusal and status 1
  local block package
  block="$(step_block "$1" "$SELECTION_STEP" "$3/selection-blocks")" || { printf 'selection-%s\n' "$block"; return 1; }
  for package in agent-runtime orch third; do
    mkdir -p "$3/work/skills/$package/runtime"
    : > "$3/work/skills/$package/runtime/Cargo.toml"
  done
  mkdir -p "$3/work/skills/linear/scripts" "$3/work/tools"
  ln -s "$ROOT/tools/ci-job-set" "$3/work/tools/ci-job-set"
  : > "$3/selection.out"
  (cd "$3/work" && RUST_TARGETS="$2" GITHUB_OUTPUT="$3/selection.out" "$BASH" "$block") >"$3/selection.log" 2>&1 ||
    { printf 'selection-refused\n'; return 1; }
}
selection_output() { # DIR NAME ; that output's value
  sed -n "s/^$2=//p" "$1/selection.out"
}
TARGETS_STEP="the package runtimes' Rust targets"
targets_runs() { # WORKFLOW SHARD OS RUST_TARGETS ; whether the targets step runs on that leg
  gh_eval value "$(jq -cn --arg shard "$2" --arg os "$3" --arg targets "$4" \
    '{matrix: {shard: $shard}, runner: {os: $os}, needs: {changes: {outputs: {rust_targets: $targets}}}}')" \
    "$(step_if "$1" "$TARGETS_STEP")"
}
check "the runtimes' targets run on the orch-rest Linux leg where a target is listed, and where no classifier ran" \
  "true true false false false" \
  "$(targets_runs "$WORKFLOW" orch-rest Linux '["orch/lib"]') $(targets_runs "$WORKFLOW" orch-rest Linux '') $(targets_runs "$WORKFLOW" orch-rest Linux '[]') $(targets_runs "$WORKFLOW" orch-rest macOS '["orch/lib"]') $(targets_runs "$WORKFLOW" orch-state Linux '["orch/lib"]')"
# The targets step's own body, over a stub cargo and privacy harness and the
# real run-all.sh: which units it hands that pool, and whether the step ends
# red, for each failure it must not hide. The stub answers the build with
# cargo's JSON artifact lines, as the real build does in the step's log, and
# each listing as libtest does; the bin targets list no test, as both
# runtimes' do, and only orch holds a doctest.
targets_step() { # WORKFLOW RUST_TARGETS FAILING ; `green|red: unit,...` with the units run, sorted
  local run block package
  run="$(mktemp -d "$TMP/targets-step.XXXXXX")" || exit 1
  block="$(step_block "$1" "$TARGETS_STEP" "$run/blocks")" || { printf '%s\n' "$block"; return 0; }
  runtime_selection "$1" "$2" "$run" || return 0
  mkdir -p "$run/bin" "$run/runner" "$run/tmp" "$run/work/skills/orch/tests" "$run/work/skills/github/scripts"
  ln -s "$ROOT/skills/orch/tests/run-all.sh" "$run/work/skills/orch/tests/run-all.sh"
  ln -s "$ROOT/skills/orch/tests/lib" "$run/work/skills/orch/tests/lib"
  ln -s "$ROOT/skills/github/scripts/lib" "$run/work/skills/github/scripts/lib"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "tests::a: test" "tests::b: test"\n' > "$run/bin/lists-tests"
  printf '#!/usr/bin/env bash\n:\n' > "$run/bin/lists-none"
  # A call fails where FAILING holds `<package> <what>`, the step's own
  # spelling of the unit.
  cat > "$run/bin/cargo" <<'STUB'
#!/usr/bin/env bash
verb="$1"
shift
manifest="" args=() mode=run
while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest-path) manifest="$2"; shift ;;
    --no-run) mode=build ;;
    --locked | --check | --all-targets | --message-format=*) ;;
    --) [[ "${2-}" != --list ]] || mode=list; break ;;
    *) args+=("$1") ;;
  esac
  shift
done
package="${manifest#skills/}"
package="${package%%/*}"
what="${args[*]-}"
case "$verb $mode" in
  "test build") what=build ;;
  "test list") what="list $what" ;;
  "test run") printf '%s\n' "$package $what" >> "$STUB_RAN" ;;
  *) what="$verb" ;;
esac
case ",$STUB_FAILING," in
  *",$package $what,"*)
    [[ "$verb $mode" != "test run" ]] || echo 'test result: FAILED. 1 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s'
    exit 101 ;;
esac
case "$verb $mode" in
  "test run") echo 'test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s' ;;
  "test list") [[ "$package" != orch ]] || echo 'src/lib.rs - f (line 1): test' ;;
  "test build")
    artifact() { printf '{"reason":"compiler-artifact","profile":{"test":true},"executable":"%s/lists-%s","target":{"kind":["%s"],"name":"%s"}}\n' "$STUB_BIN" "$3" "$1" "$2"; }
    printf '{"reason":"build-finished","success":true}\n'
    [[ ${#args[@]} -gt 0 ]] || { artifact lib "$package" tests; artifact bin "$package" none; artifact test one tests; artifact test two tests; exit 0; }
    set -- "${args[@]}"
    while [[ $# -gt 0 ]]; do
      case "$1" in --lib) artifact lib "$package" tests ;; --test) artifact test "$2" tests; shift ;; esac
      shift
    done ;;
esac
exit 0
STUB
  chmod +x "$run/bin/cargo" "$run/bin/lists-tests" "$run/bin/lists-none"
  for package in agent-runtime orch third; do
    mkdir -p "$run/work/skills/$package/tests/privacy"
    printf 'printf "%%s\\n" "%s privacy" >> "$STUB_RAN"\ncase ",$STUB_FAILING," in *",%s privacy,"*) echo "pass: 0  fail: 1"; exit 1 ;; esac\necho "pass: 1  fail: 0"\n' \
      "$package" "$package" > "$run/work/skills/$package/tests/privacy/privacy-cases.sh"
  done
  : > "$run/ran"
  if (cd "$run/work" && env -u RUN_ALL_NATIVE_CONTRACTS -u RUN_ALL_SUITE_SECS -u RUN_ALL_DEADLINE_EPOCH \
    -u RUN_ALL_REVIEW_SECS -u RUN_ALL_PENDING_SUITES PATH="$run/bin:$PATH" TMPDIR="$run/tmp" \
    RUNNER_TEMP="$run/runner" TARGETS="$(selection_output "$run" targets)" \
    PACKAGES="$(selection_output "$run" packages)" STUB_FAILING="$3" STUB_RAN="$run/ran" STUB_BIN="$run/bin" \
    "$BASH" "$block") >"$run/log" 2>&1; then
    printf 'green: '
  else
    printf 'red: '
  fi
  LC_ALL=C sort "$run/ran" | paste -sd, -
}
LISTED='agent-runtime --test controller,agent-runtime privacy,orch --doc,orch --lib,orch privacy'
BOTH_WHOLE='agent-runtime --lib,agent-runtime --test one,agent-runtime --test two,agent-runtime privacy,orch --doc,orch --lib,orch --test one,orch --test two,orch privacy'
while IFS='|' read -r label targets failing expected; do
  check "the targets step: $label" "$expected" "$(targets_step "$WORKFLOW" "$targets" "$failing")"
done <<TARGETS
every listed unit passes, the doctests of a listed lib among them|["agent-runtime/controller","orch/lib"]||green: $LISTED
a whole manifest runs each test executable that lists a test, and its doctests|["orch/*"]||green: orch --doc,orch --lib,orch --test one,orch --test two,orch privacy
no classifier ran, so every runtime the tree has runs whole|||green: $BOTH_WHOLE,third --lib,third --test one,third --test two,third privacy
a failed target reds the step|["agent-runtime/controller","orch/lib"]|agent-runtime --test controller|red: $LISTED
a failed privacy harness reds the step|["agent-runtime/controller","orch/lib"]|orch privacy|red: $LISTED
a failed fmt or clippy reds the step and stops no unit|["agent-runtime/controller","orch/lib"]|agent-runtime fmt,orch clippy|red: $LISTED
a failed build reds the step and runs that package's privacy harness|["agent-runtime/controller","orch/lib"]|orch build|red: agent-runtime --test controller,agent-runtime privacy,orch privacy
a failed doctest listing reds the step|["orch/lib"]|orch list --doc|red: orch --lib,orch privacy
TARGETS
plant "$WORKFLOW" "            exit 1" "            :" "$TMP/targets-unfailed.yml" \
  "skill-suites-shard/$TARGETS_STEP" line
check "must-fail: a failed list that ends without exit 1 leaves a failed target's step green" "green: $LISTED" \
  "$(targets_step "$TMP/targets-unfailed.yml" '["agent-runtime/controller","orch/lib"]' 'agent-runtime --test controller')"

# The runtimes' lockfiles against their dependency policy: which legs install
# cargo-deny, on which events, and that the check runs exactly where it was
# installed. A merge group's Linux leg holds it under CI, and the night, which
# runs no Linux shard, holds it on its macOS leg.
DENY_INSTALL_STEP="cargo-deny, the pinned release"
DENY_STEP="the package runtimes' lockfiles, held to their dependency policy"
deny_installs() { # WORKFLOW SHARD OS EVENT RUST_TARGETS ; whether the install step runs on that leg
  gh_eval value "$(jq -cn --arg shard "$2" --arg os "$3" --arg event "$4" --arg targets "$5" \
    '{matrix: {shard: $shard}, runner: {os: $os}, github: {event_name: $event}, needs: {changes: {outputs: {rust_targets: $targets}}}}')" \
    "$(step_if "$1" "$DENY_INSTALL_STEP")"
}
while IFS='|' read -r label shard os event targets expected; do
  check "the lockfile policy installs: $label" "$expected" "$(deny_installs "$WORKFLOW" "$shard" "$os" "$event" "$targets")"
done <<'DENY_LEGS'
a merge group's orch-rest Linux leg, a target listed|orch-rest|Linux|merge_group|["orch/lib"]|true
a merge group whose changes job published no list|orch-rest|Linux|merge_group||true
a main push owing a target|orch-rest|Linux|push|["agent-runtime/lib"]|true
a merge group whose reach holds no target|orch-rest|Linux|merge_group|[]|false
a merge group's macOS orch-rest leg, which the Linux leg covers|orch-rest|macOS|merge_group|["orch/lib"]|false
the night, on its macOS orch-rest leg|orch-rest|macOS|schedule||true
a manual dispatch, on its macOS orch-rest leg|orch-rest|macOS|workflow_dispatch||true
another shard|orch-state|Linux|merge_group|["orch/lib"]|false
DENY_LEGS
for outcome in success skipped failure; do
  check "the lockfile check runs where the install's outcome is $outcome: $([[ $outcome == success ]] && echo yes || echo no)" \
    "$([[ $outcome == success ]] && echo true || echo false)" \
    "$(gh_eval value "{\"steps\":{\"cargo-deny\":{\"outcome\":\"$outcome\"}}}" "$(step_if "$WORKFLOW" "$DENY_STEP")")"
done
plant "$WORKFLOW" " || github.event_name == 'schedule'" "" "$TMP/deny-no-night.yml" "skill-suites-shard/$DENY_INSTALL_STEP"
check "must-fail: an install condition without the schedule leaves the night unchecked" false \
  "$(deny_installs "$TMP/deny-no-night.yml" orch-rest macOS schedule '')"
# The check step's own body, over the selection step and a stub cargo that
# answers `cargo deny` for each manifest: which packages it holds to which
# policy, and whether the step ends red.
deny_step() { # WORKFLOW RUST_TARGETS FAILING ; `green|red: <package> <policy>,...` for each package checked, sorted
  local run block package
  run="$(mktemp -d "$TMP/deny-step.XXXXXX")" || exit 1
  block="$(step_block "$1" "$DENY_STEP" "$run/blocks")" || { printf '%s\n' "$block"; return 0; }
  runtime_selection "$1" "$2" "$run" || return 0
  mkdir -p "$run/bin"
  cp "$ROOT/skills/agent-runtime/runtime/deny.toml" "$run/work/skills/agent-runtime/runtime/deny.toml"
  # A package fails where FAILING names it; a policy path naming no file is
  # recorded as missing, as cargo-deny refuses a config it cannot read.
  cat > "$run/bin/cargo" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == deny ]] || exit 0
shift
manifest="" config=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest-path) manifest="$2"; shift ;;
    --config) config="$2"; shift ;;
  esac
  shift
done
package="${manifest#skills/}"
package="${package%%/*}"
[[ -f "$config" ]] || config="missing:$config"
printf '%s %s\n' "$package" "$config" >> "$STUB_RAN"
case ",$STUB_FAILING," in *",$package,"*) echo 'licenses FAILED'; exit 4 ;; esac
echo 'advisories ok, bans ok, licenses ok, sources ok'
STUB
  chmod +x "$run/bin/cargo"
  : > "$run/ran"
  if (cd "$run/work" && PATH="$run/bin:$PATH" PACKAGES="$(selection_output "$run" packages)" STUB_FAILING="$3" \
    STUB_RAN="$run/ran" "$BASH" "$block") >"$run/log" 2>&1; then
    printf 'green: '
  else
    printf 'red: '
  fi
  LC_ALL=C sort "$run/ran" | paste -sd, -
}
DENY_POLICY=skills/agent-runtime/runtime/deny.toml
BOTH_HELD="agent-runtime $DENY_POLICY,orch $DENY_POLICY"
while IFS='|' read -r label targets failing expected; do
  check "the lockfile check: $label" "$expected" "$(deny_step "$WORKFLOW" "$targets" "$failing")"
done <<DENY_BODY
a listed target holds its own package alone|["orch/lib"]||green: orch $DENY_POLICY
targets of both packages hold each once|["agent-runtime/controller","agent-runtime/lib","orch/*"]||green: $BOTH_HELD
a failed package reds the step and stops no other|["agent-runtime/lib","orch/lib"]|agent-runtime|red: $BOTH_HELD
DENY_BODY
plant "$WORKFLOW" "failed packages=\${failed# }\" >&2; exit 1; }" "failed packages=\${failed# }\" >&2; }" \
  "$TMP/deny-unfailed.yml" "skill-suites-shard/$DENY_STEP"
check "must-fail: a failed package that ends without exit 1 leaves the step green" "green: $BOTH_HELD" \
  "$(deny_step "$TMP/deny-unfailed.yml" '["agent-runtime/lib","orch/lib"]' agent-runtime)"
# Both steps hold the set the selection step reads, so a fallback written
# out by hand in place of the tree's discovery leaves the third runtime out
# of both together where no list was published.
plant "$WORKFLOW" '"$(tools/ci-job-set --all-rust-targets)"' "'[\"agent-runtime/*\",\"orch/*\"]'" \
  "$TMP/selection-literal.yml" "skill-suites-shard/$SELECTION_STEP"
check "must-fail: a hand-written fallback leaves a runtime out of the lockfile check and the targets step alike" \
  "green: $BOTH_HELD|green: $BOTH_WHOLE" \
  "$(deny_step "$TMP/selection-literal.yml" '' '')|$(targets_step "$TMP/selection-literal.yml" '' '')"

# Unknown additions use actual workflow discovery and per-path selection.
# The input families include the removed empty-shard seams.
rm -- "$PART/skills"
cp -R "$POOL/skills" "$PART/skills"
rm -- "$PART/tools/tests"
cp -R "$POOL/tools/tests" "$PART/tools/tests"
rm -- "$PART/hooks" "$PART/refresh"
cp -R "$POOL/hooks" "$PART/hooks"
cp -R "$POOL/refresh" "$PART/refresh"
PARTITION_POOL_CLAIMS="$TMP/unknown-pool-claims"
mkdir -p "$PARTITION_POOL_CLAIMS"
: > "$TMP/unknown-paths"
: > "$TMP/unknown-linux-owners"
: > "$TMP/unknown-macos-owners"
while IFS='|' read -r path linux_owner macos_owner; do
  for tree in "$PART" "$POOL" "$GITHUB_SELECT"; do
    mkdir -p "$tree/${path%/*}"
    stub_suite "$tree/$path"
  done
  printf '%s\n' "$path" >> "$TMP/unknown-paths"
  printf '%s\t%s\n' "$linux_owner" "$path" >> "$TMP/unknown-linux-owners"
  printf '%s\t%s\n' "$macos_owner" "$path" >> "$TMP/unknown-macos-owners"
done <<'UNKNOWN'
skills/worktree/tests/worktree_future_restack.sh|worktree-restack|worktree
tools/tests/native-future.test.sh|guards-tools|guards-tools
skills/commit-guards/tests/pre-push-future.test.sh|guards-commit|guards-commit
skills/linear/tests/native-future.test.sh|linear|linear
skills/deep-research/tests/native-future.sh|rest|rest
skills/slack/tests/worker-stall.test.sh|slack|slack
skills/jarvis/tests/native-future.test.sh|jarvis|rest
UNKNOWN
sort -o "$TMP/unknown-paths" "$TMP/unknown-paths"
git -C "$GITHUB_SELECT" add .
cp "$JOB_SET" "$GITHUB_SELECT/tools/ci-job-set"
for os in ubuntu-latest macos-latest; do
  major=4; platform=linux
  [[ "$os" != macos-latest ]] || { major=3; platform=macos; }
  cp "$TMP/unknown-paths" "$TMP/os-universe"
  os_claims "$WORKFLOW" "$os" "$major" > "$TMP/unknown-claims"
  check "unknown families execute exactly once on $os" \
    "$(cat "$TMP/unknown-paths")" "$(cat "$TMP/unknown-claims")"
  while IFS=$'\t' read -r owner path; do
    check "unknown $path reaches $owner on $os" "$owner"$'\t'"$path" \
      "$(grep -xF "$owner"$'\t'"$path" "$TMP/os-owners")"
  done < "$TMP/unknown-$platform-owners"
done
check "unknown Mac families select their retained jobs with event parity" "" \
  "$(unselected_owners "$GITHUB_SELECT/tools/ci-job-set" "$TMP/unknown-macos-owners" "$GITHUB_SELECT" queue_macos_shards)"

needle='            case "$base" in *restack*) [ -n "${RUN_ALL_NATIVE_CONTRACTS:-}" ] || continue ;; esac'
NEEDLE="$needle" REPLACEMENT='            case "$base" in *restack*) continue ;; esac' \
  awk '$0 == ENVIRON["NEEDLE"] { $0 = ENVIRON["REPLACEMENT"]; n++ } {print} END {exit n != 1}' \
  "$WORKFLOW" > "$TMP/unknown-restack.yml" || bad "restack retention control changed no workflow owner"
os_claims "$TMP/unknown-restack.yml" macos-latest 3 > "$TMP/unknown-restack-claims"
check "must-fail: a restack filter without its retention loses its unresolved suite" \
  skills/worktree/tests/worktree_future_restack.sh \
  "$(comm -23 "$TMP/unknown-paths" "$TMP/unknown-restack-claims")"

NEEDLE='          set -- skills/linear/tests/*.sh' REPLACEMENT='          set -- skills/linear/tests/*.sh; set -- skills/linear/tests/bash4-runtime-contract.test.sh' \
  awk '$0 == ENVIRON["NEEDLE"] { $0 = ENVIRON["REPLACEMENT"]; n++ } {print} END {exit n != 1}' \
  "$WORKFLOW" > "$TMP/unknown-linear.yml" || bad "linear retention control changed no workflow owner"
os_claims "$TMP/unknown-linear.yml" macos-latest 3 > "$TMP/unknown-linear-claims"
check "must-fail: a linear roster without its retention loses its unresolved suite" \
  skills/linear/tests/native-future.test.sh \
  "$(comm -23 "$TMP/unknown-paths" "$TMP/unknown-linear-claims")"

# Linux rest releases Jarvis to its shard; macOS rest keeps the family's
# native and unresolved suites, because macOS runs no jarvis leg, less the
# four suites the macOS guards-hooks, guards-tools and orch-state legs run by
# path, both mixed suites among them. Releasing on both loses the rest of the
# family on macOS; releasing on neither runs each suite twice on Linux; a
# macOS rest blind to those paths runs the four twice there. A deleted path
# step returns its suites to macOS rest.
jarvis_arm='              jarvis) [ -n "${RUN_ALL_NATIVE_CONTRACTS:-}" ] || needle="skills/$x/tests/*.sh" ;;'
jarvis_skip='                grep -qF -- "$t" <<<"$claims" || unclaimed+=("$t")'
jarvis_moved="$(printf '%s\n' skills/jarvis/tests/session.test.sh skills/jarvis/tests/succession.test.sh \
  skills/jarvis/tests/controls.test.sh skills/jarvis/tests/watch-loop.test.sh | sort)"
(cd "$ROOT" && printf '%s\n' skills/jarvis/tests/*.test.sh) > "$TMP/jarvis-suites"
# Each moved suite is a required member of the discovered family; each row
# below refuses a fault whose expected set is empty, so a macOS rest left no
# unmoved Jarvis suite fails there.
undiscovered="$(grep -vxF -f "$TMP/jarvis-suites" <<<"$jarvis_moved" || true)"
[[ -z "$undiscovered" ]] ||
  bad "the moved Jarvis suites ${undiscovered//$'\n'/ } were not discovered, so the Jarvis retention controls prove nothing"
jarvis_universe() { # OS ; the eligible Jarvis suites, unresolved ones included, into os-universe
  cp "$TMP/jarvis-suites" "$TMP/jarvis-eligible"
  if [[ "$1" == macos-latest ]]; then
    "$ROOT/tools/macos-test-contracts" --filter <"$TMP/jarvis-suites" >"$TMP/jarvis-eligible" || exit 1
  fi
  sort -u "$TMP/jarvis-eligible" <(grep '^skills/jarvis/' "$TMP/unknown-paths") > "$TMP/os-universe"
}
while IFS='|' read -r os major fault target expected replacement; do
  case "$target" in arm) needle="$jarvis_arm" ;; skip) needle="$jarvis_skip" ;; esac
  mutant="$TMP/jarvis-$target-$fault.yml"
  NEEDLE="$needle" REPLACEMENT="$replacement" \
    awk '$0 == ENVIRON["NEEDLE"] { $0 = ENVIRON["REPLACEMENT"]; n++ } {print} END {exit n != 1}' \
    "$WORKFLOW" > "$mutant" || { bad "jarvis $target $fault control changed no workflow owner"; continue; }
  jarvis_universe "$os"
  os_claims "$mutant" "$os" "$major" > "$TMP/jarvis-claims"
  case "$fault" in
    lost) got="$(comm -23 "$TMP/os-universe" "$TMP/jarvis-claims")" ;;
    duplicated) got="$(uniq -d "$TMP/jarvis-claims")" ;;
  esac
  case "$expected" in
    family) want="$(cat "$TMP/os-universe")" ;;
    unmoved) want="$(comm -23 "$TMP/os-universe" <(printf '%s\n' "$jarvis_moved"))" ;;
    moved) want="$jarvis_moved" ;;
  esac
  [[ -n "$want" ]] || bad "the jarvis $target $fault control expects no suite, so it proves nothing"
  check "must-fail: a Jarvis rest $target changed leaves the $expected Jarvis suites $fault on $os" \
    "$want" "$got"
done <<'ROWS'
macos-latest|3|lost|arm|unmoved|              jarvis) needle="skills/$x/tests/*.sh" ;;
ubuntu-latest|4|duplicated|arm|family|              jarvis) needle="" ;;
macos-latest|3|duplicated|skip|moved|                unclaimed+=("$t")
ROWS
jarvis_universe macos-latest
for step in 'Jarvis session suite on macOS' 'Jarvis succession suite on macOS' \
  'Jarvis controls and watch-loop suites on macOS'; do
  mutant="$TMP/jarvis-step-removed.yml"
  awk -v owner="      - name: $step" '
    $0 == owner { drop = 1; hits++; next }
    drop && substr($0, 1, 8) == "      - " { drop = 0 }
    drop { next }
    { print }
    END { exit hits != 1 }
  ' "$WORKFLOW" > "$mutant" || { bad "the step '$step' is no longer one step in the workflow"; continue; }
  os_claims "$mutant" macos-latest 3 > "$TMP/jarvis-claims"
  check "a deleted '$step' step returns its suites to macOS rest, once" \
    "$(cat "$TMP/os-universe")" "$(cat "$TMP/jarvis-claims")"
done
cp "$TMP/unknown-paths" "$TMP/os-universe"

sed 's/want_shard rest; break;/:; break;/' "$JOB_SET" > "$GITHUB_SELECT/tools/ci-job-set"
edited "$JOB_SET" "$GITHUB_SELECT/tools/ci-job-set" unknown-package-selector
check "must-fail: node-only package selection misses its unresolved shell suite" \
  $'rest\tskills/deep-research/tests/native-future.sh' \
  "$(unselected_owners "$GITHUB_SELECT/tools/ci-job-set" "$TMP/unknown-macos-owners" "$GITHUB_SELECT" queue_macos_shards)"

sed 's/contracts.get(relative, "unresolved")/contracts.get(relative, "linux-duplicate")/' \
  "$ROOT/tools/macos-test-contracts" > "$POOL/tools/macos-test-contracts"
edited "$ROOT/tools/macos-test-contracts" "$POOL/tools/macos-test-contracts" unknown-retention
PARTITION_POOL_CLAIMS="$TMP/unknown-drop-pool"
mkdir -p "$PARTITION_POOL_CLAIMS"
os_claims "$WORKFLOW" macos-latest 3 > "$TMP/unknown-drop-claims"
check "must-fail: dropping unknown eligibility loses every unresolved family" \
  "$(cat "$TMP/unknown-paths")" "$(comm -23 "$TMP/unknown-paths" "$TMP/unknown-drop-claims")"
cp "$ROOT/tools/macos-test-contracts" "$POOL/tools/macos-test-contracts"

fi

if [[ "$mode" != shell ]]; then

check "Cargo name checks run only after the macOS CLI rest compile, never on the push" \
  " --cargo-only:true::matrix.crate == 'kendex-cli' && matrix.leg == 'rest' && github.event_name != 'push'" \
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
refresh_fresh_clone::|apply-locked
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
for defect in selector skip toggle-selector toggle-skip apply-leg-drop apply-skip refresh-selector refresh-skip forwarding export unit-filter; do
  mutant="$TMP/wf-cargo-filter-$defect.yml"
  case "$defect" in
    selector) sed "s/filters='verify_ lock_record:: toggle_locked::'/filters='lock_record:: toggle_locked::'/" "$WORKFLOW" > "$mutant" ;;
    skip) sed 's/--skip verify_ //' "$WORKFLOW" > "$mutant" ;;
    toggle-selector) sed "s/filters='verify_ lock_record:: toggle_locked::'/filters='verify_ lock_record::'/" "$WORKFLOW" > "$mutant" ;;
    toggle-skip) sed 's/ --skip toggle_locked:://' "$WORKFLOW" > "$mutant" ;;
    apply-leg-drop) sed 's/, apply-locked\]/]/' "$WORKFLOW" > "$mutant" ;;
    apply-skip) sed 's/ --skip apply_locked:://' "$WORKFLOW" > "$mutant" ;;
    refresh-selector) sed 's/apply_locked:: refresh_ --skip verify_/apply_locked:: --skip verify_/' "$WORKFLOW" > "$mutant" ;;
    refresh-skip) sed 's/ --skip refresh_//' "$WORKFLOW" > "$mutant" ;;
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
  if [[ "$defect" == selector || "$defect" == toggle-selector || "$defect" == apply-leg-drop || "$defect" == refresh-selector ]]; then
    lost="$(comm -23 "$INTEGRATION_TESTS" <(sort -u "$TMP/integration-$defect"))"
    if [[ "$defect" == toggle-selector || "$defect" == apply-leg-drop ]]; then
      family=toggle_locked::
      [[ "$defect" != apply-leg-drop ]] || family=apply_locked::
      check "must-fail: dropped $defect leaves every $family test unclaimed" \
        "$(sed -n "/^$family/p" "$INTEGRATION_TESTS")" "$(sed -n "/^$family/p" <<<"$lost")"
      if [[ "$defect" == apply-leg-drop ]]; then
        check 'must-fail: dropped apply leg also loses the non-verification refresh names' \
          "$(grep -F refresh_ "$INTEGRATION_TESTS" | grep -vF verify_ || true)" \
          "$(grep -F refresh_ <<<"$lost" || true)"
      fi
    else
      [[ -n "$lost" ]] && ok "must-fail: a dropped selector names unclaimed integration tests" ||
        bad "must-fail: a dropped selector leaves no unclaimed integration test"
    fi
  else
    repeated="$(uniq -d "$TMP/integration-$defect")"
    if [[ "$defect" == toggle-skip || "$defect" == apply-skip ]]; then
      family=toggle_locked::
      [[ "$defect" != apply-skip ]] || family=apply_locked::
      expected="$(sed -n "/^$family/p" "$INTEGRATION_TESTS")"
      if [[ "$defect" == apply-skip ]]; then
        # Names also excluded by refresh_ cannot reach the removed skip.
        expected="$(grep -vF refresh_ <<<"$expected" || true)"
      fi
      check "must-fail: dropped $defect repeats each name held only by that skip" \
        "$expected" "$repeated"
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
