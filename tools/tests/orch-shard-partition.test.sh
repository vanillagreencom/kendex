#!/usr/bin/env bash
# The orch battery outgrew one CI shard, so `.github/workflows/skill-tests.yml`
# runs it as four, and a shard is nothing but a `run-all.sh` name filter:
# `open-terminal`, `oversee`, a third set of name fragments, and the negation
# of all three. That makes the filters load-bearing. A filter that stopped
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
# Five surfaces:
#   1. the filter — a bare argument selects, `!name` rejects, several
#      arguments are a union, an empty one refuses, and a filter that matches
#      no suite exits non-zero instead of reporting an empty pass
#   2. the orch partition — the filters the workflow passes, read out of the
#      workflow rather than restated here, leave every suite in exactly one
#      shard. The must-fail arms drop a shard and repeat a shard, the two ways
#      that guarantee breaks.
#   3. the shell-shard partition — every file under skills/*/tests/*.sh,
#      tools/tests/*.test.sh and hooks/tests/*.sh is claimed by exactly one
#      shard. The must-fail arms drop a roster, repeat a roster, leave a moved
#      path in a comment where only prose can see it, and delete the step that
#      globs a package.
#   4. the citations — a shard a tracked file names in backticks is one the
#      matrix declares, so a rename cannot leave prose pointing at a lane no
#      leg runs.
#   5. the cargo legs' partition — the macOS kendex-cli lane splits by
#      `--test` target, and every test target `cargo metadata` reports for
#      that crate is claimed by exactly one leg. The must-fail arms drop a
#      leg's roster and repeat a target across two legs.
#
# The roster is real and the suites are not: every run below happens in a
# sandbox holding a copy of run-all.sh and one empty file per suite name, or a
# copy of the workflow and a `bash` that does nothing, so the real filter and
# roster logic runs over the real names without running the battery.
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which would resolve ROOT to the hook's
# repository instead of this one.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

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

# --- 3. The shell shards' partition over every suite FILE -------------------
# Section 2 judges one seam, the orch battery's name filters. The rest of the
# workflow is a second seam and a coarser one: six steps loop over rosters of
# suite files, and since two of them name individual paths inside a package a
# third one globs, the file-level partition can no longer be read off the
# globs. Each of the six also carries a fallback that runs a suite here when
# no other step claims it, and a fallback satisfied by a path written in a
# COMMENT would let two shards both skip the same suite and both exit 0. The
# aggregator asserts job success, never suite count, so nothing downstream
# sees the loss.
#
# Rosters are taken by RUNNING each step's run block against a `bash` that
# does nothing, in a sandbox whose workflow is the copy under test and whose
# skills/, tools/ and hooks/ are this tree. What a block prints as
# `=== <path>` is its roster, produced by that block's own globs, skip arms
# and fallbacks rather than by a second reading of them here.
#
# The file keeps its name: the orch filters above are still the seam most
# likely to be edited, and this section is the same invariant one level out.

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

# The sandbox: the workflow under test at the path a step's `$wf` spells, and
# the real trees its globs expand over.
PART="$TMP/partition"
mkdir -p "$PART/.github/workflows"
ln -s "$ROOT/skills" "$PART/skills"
ln -s "$ROOT/tools"  "$PART/tools"
ln -s "$ROOT/hooks"  "$PART/hooks"
# `bash "$t"` in a roster loop resolves to this and does nothing, so a loop
# prints its roster without running a suite. Only `bash` is shimmed; grep, sed
# and printf stay the host's.
SHIM="$TMP/shim"
mkdir -p "$SHIM"
printf '#!/bin/sh\nexit 0\n' > "$SHIM/bash"
chmod +x "$SHIM/bash"

# A roster step is one that reports its suites as `=== <path>`. That marker is
# what makes it a roster loop, so the selector needs no list of step names:
# the orch steps hand their names to run-all.sh and print none of their own,
# and the node steps run no shell suite at all.
ROSTER_MARK='=== $t'

split_run_blocks() { # split_run_blocks <workflow> <dir> ; one <dir>/N.sh per block
  local wf="$1" dir="$2" n=0 line
  rm -rf -- "${dir:?}"
  mkdir -p "$dir"
  while IFS= read -r line; do
    case "$line" in
      '@@'*) n=$((n + 1)); : > "$dir/$n.sh" ;;
      *)
        if [[ "$n" -gt 0 ]]; then printf '%s\n' "${line#>}" >> "$dir/$n.sh"; fi ;;
    esac
  done < <(awk -f "$BLOCK_AWK" "$wf")
}

claims_of() { # claims_of <workflow> ; every path its roster steps claim
  local wf="$1" dir="$TMP/blocks" f line
  cp "$wf" "$PART/.github/workflows/skill-tests.yml"
  split_run_blocks "$wf" "$dir"
  for f in "$dir"/*.sh; do
    grep -qF "$ROSTER_MARK" "$f" || continue
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

# The universe: the three globs the roster steps loop over, less the runner
# the orch steps invoke by path. That runner drives the battery and is not a
# suite, the same exclusion section 2's roster makes by name.
UNIV="$TMP/universe"
(
  cd "$ROOT" || exit 1
  for f in skills/*/tests/*.sh tools/tests/*.test.sh hooks/tests/*.sh; do
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

# --- 3b. Must-fail: the three ways this partition breaks --------------------
# Each arm mutates a copy of the workflow, and the section above must name the
# damage. An arm that stays clean means the section reports nothing.

# A roster no fallback covers, dropped. No skip list points at tools/tests, so
# its files land in no shard at all.
wf_drop="$TMP/wf-roster-dropped.yml"
awk '{
  if (index($0, "for t in tools/tests/*.test.sh hooks/tests/*.sh"))
    sub(/tools\/tests\/\*\.test\.sh /, "")
  print
}' "$WORKFLOW" > "$wf_drop"
claims_file "$wf_drop" "$TMP/claims-drop"
if [[ -n "$(comm -23 "$UNIV" <(sort -u "$TMP/claims-drop"))" ]]; then
  ok "must-fail: a dropped roster leaves its files unclaimed, and they are named"
else
  bad "must-fail: dropping a roster left nothing unclaimed, so the coverage check proves nothing"
fi

# A roster claimed twice.
wf_twice="$TMP/wf-roster-repeated.yml"
awk '{
  if (index($0, "for t in skills/review-gate/tests/*.sh; do"))
    sub(/; do/, " skills/worktree/tests/*.sh; do")
  print
}' "$WORKFLOW" > "$wf_twice"
claims_file "$wf_twice" "$TMP/claims-twice"
if [[ -n "$(uniq -d "$TMP/claims-twice")" ]]; then
  ok "must-fail: a roster added to a second step is named as claimed twice"
else
  bad "must-fail: a repeated roster produced no duplicate, so the overlap check proves nothing"
fi

# A moved path left only in a comment. The fallback in `guards-commit` reads
# run-block text, so it reclaims the suite and the partition holds; with that
# filter removed it reads the comment instead, skips the suite, and the suite
# runs in no shard. The pair is one arm: the first half says the fallback
# fires, the second says this section is what catches it when it does not.
wf_prose="$TMP/wf-path-in-comment.yml"
awk '{
  if ($0 ~ /^ *skills\/commit-guards\/tests\/install-git-hooks\.test\.sh \\$/) next
  if (index($0, "for t in tools/tests/*.test.sh hooks/tests/*.sh"))
    print "          # skills/commit-guards/tests/install-git-hooks.test.sh"
  print
}' "$WORKFLOW" > "$wf_prose"
claims_file "$wf_prose" "$TMP/claims-prose"
check "a moved path left only in a comment is reclaimed by its fallback shard" \
  "" "$(comm -23 "$UNIV" <(sort -u "$TMP/claims-prose"))"

wf_open="$TMP/wf-path-in-comment-fallback-open.yml"
awk '{
  if ($0 ~ /claims="\$\(grep -v/) { print "          claims=\"$(cat \"$wf\")\""; next }
  print
}' "$wf_prose" > "$wf_open"
claims_file "$wf_open" "$TMP/claims-open"
if [[ -n "$(comm -23 "$UNIV" <(sort -u "$TMP/claims-open"))" ]]; then
  ok "must-fail: with the comment filter removed, the prose-only path runs in no shard and is named"
else
  bad "must-fail: a fallback matching comment text left nothing unclaimed, so the filter is unproven"
fi

# The step that globs a package, deleted. `rest` skips a package only where
# this file still runs it, and the needle it looks for is the owning loop's
# glob, which leaves with that loop; the package's suites come back here
# instead of going nowhere. The two paths `guards-tools` spells stay, so they
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
claims_file "$wf_nostep" "$TMP/claims-nostep"
check "with the step that globs a package deleted, no suite of it is unclaimed" \
  "" "$(comm -23 "$UNIV" <(sort -u "$TMP/claims-nostep"))"

wf_prefix="$TMP/wf-prefix-needle.yml"
awk '{ sub(/needle="skills\/\$x\/tests\/\*\.sh"/, "needle=\"skills/$x/tests/\""); print }' \
  "$wf_nostep" > "$wf_prefix"
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
cited_shards() { # cited_shards ; NUL paths on stdin -> path:line:name per citation
  { xargs -0 grep -HIonE '`[a-z0-9][a-z0-9-]*` shards?' 2>/dev/null || true; } |
    sed 's/:`\([a-z0-9-]*\)` shards\{0,1\}$/:\1/'
}

declared_shards="$(sed -n 's/^ \{8\}shard: \[\(.*\)\]$/\1/p' "$WORKFLOW" |
  tr -d ' ' | tr ',' '\n' | sort -u)"
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

# --- 5. The cargo legs' partition over the CLI's test targets --------------
# A cargo leg is a roster of `--test` names, and the seam it cuts is inside
# one package rather than across the workspace, so the crate guard in that job
# cannot see it. The universe comes from `cargo metadata`, the one reader of a
# crate's target list; the claims come from RUNNING the workflow's own roster
# step once per leg, so what a leg claims is what that step's case arm prints
# rather than a second reading of it here. The leg names come from the same
# matrix the job expands; a leg added there with no case arm is the roster
# step's own refusal and reds that job, not this file.
#
# The two shape reads this section depends on — the matrix leg list and the
# step that echoes a roster — are asserted here rather than inside
# leg_claims, whose callers run it in a pipeline or a substitution where a
# counter bumped in the subshell would be discarded.
CARGO_TARGET_MARK='cargo-targets: $flags'
CARGO_CRATE=kendex-cli

cli_targets() { # cli_targets ; CARGO_CRATE's test target names, one per line
  ( cd "$ROOT" && cargo metadata --format-version 1 --no-deps --locked ) |
    jq -r --arg crate "$CARGO_CRATE" '
      .packages[] | select(.name == $crate)
      | .targets[] | select(.kind[0] == "test") | .name' | sort
}

cargo_legs_of() { # cargo_legs_of <workflow> ; one matrix leg name per line
  sed -n 's/^ \{8\}leg: \[\(.*\)\]$/\1/p' "$1" | tr -d ' ' | tr ',' '\n' |
    sort -u
}

leg_claims() { # leg_claims <workflow> ; one `--test` name per claim, per leg
  local wf="$1" dir="$TMP/cargo-blocks" f leg
  split_run_blocks "$wf" "$dir"
  for f in "$dir"/*.sh; do
    grep -qF "$CARGO_TARGET_MARK" "$f" || continue
    while IFS= read -r leg; do
      [[ -n "$leg" ]] || continue
      # The step writes its roster to GITHUB_ENV for the steps after it and
      # echoes it for the log; the echo is what is read here.
      LEG="$leg" GITHUB_ENV="$TMP/github-env" "$BASH" "$f" 2>/dev/null |
        sed -n 's/^cargo-targets: //p' |
        awk '{ for (i = 1; i <= NF; i++) if ($i == "--test") print $(i + 1) }'
    done < <(cargo_legs_of "$wf")
  done
}

CLI_TARGETS="$TMP/cli-targets"
CARGO_ERR="$TMP/cargo-metadata.err"
if ! cli_targets > "$CLI_TARGETS" 2> "$CARGO_ERR"; then
  bad "cargo metadata did not run, so no cargo leg roster can be judged: $(head -n 1 "$CARGO_ERR")"
  : > "$CLI_TARGETS"
elif [[ ! -s "$CLI_TARGETS" ]]; then
  bad "cargo metadata reported no test target for $CARGO_CRATE, so the extractor is broken, not the crate sparse"
fi

if [[ -z "$(cargo_legs_of "$WORKFLOW")" ]]; then
  bad "no leg matrix in $WORKFLOW, so no cargo leg roster can be judged"
fi
split_run_blocks "$WORKFLOW" "$TMP/cargo-blocks-head"
check "exactly one run block echoes a cargo target roster" "1" \
  "$({ grep -lF "$CARGO_TARGET_MARK" "$TMP/cargo-blocks-head"/*.sh || true; } |
    wc -l | tr -d ' ')"

LEG_CLAIMS="$TMP/leg-claims-head"
leg_claims "$WORKFLOW" | sort > "$LEG_CLAIMS"

check "every $CARGO_CRATE test target is claimed by one of the workflow's cargo legs" \
  "" "$(comm -23 "$CLI_TARGETS" <(sort -u "$LEG_CLAIMS"))"
check "no $CARGO_CRATE test target is claimed by two of them" \
  "" "$(uniq -d "$LEG_CLAIMS")"

# --- 5b. Must-fail: the two ways this partition breaks ---------------------
# One leg's roster emptied leaves the targets only it named in no leg; a
# target added to a second leg runs twice and pays its seconds twice. An arm
# whose needle stopped matching mutates nothing and reports nothing, which is
# what the else branches say.
wf_leg_drop="$TMP/wf-cargo-leg-dropped.yml"
awk '{ sub(/--test catalog_check/, ""); print }' "$WORKFLOW" > "$wf_leg_drop"
if [[ -n "$(comm -23 "$CLI_TARGETS" <(leg_claims "$wf_leg_drop" | sort -u))" ]]; then
  ok "must-fail: an emptied cargo leg roster leaves its targets unclaimed, and they are named"
else
  bad "must-fail: emptying a cargo leg roster left nothing unclaimed, so the coverage check proves nothing"
fi

wf_leg_twice="$TMP/wf-cargo-leg-repeated.yml"
awk '{ sub(/--lib --bins/, "--lib --bins --test catalog_check"); print }' \
  "$WORKFLOW" > "$wf_leg_twice"
if [[ -n "$(leg_claims "$wf_leg_twice" | sort | uniq -d)" ]]; then
  ok "must-fail: a target added to a second cargo leg is named as claimed twice"
else
  bad "must-fail: a repeated cargo target produced no duplicate, so the overlap check proves nothing"
fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
