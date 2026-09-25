#!/usr/bin/env bash
# What `.github/workflows/skill-tests.yml` runs is keyed to the change class,
# and the keying is in three places that have to agree: `tools/ci-job-set`
# turns a class into one line per lane, each job's `if:` reads one of those
# lines, and `tools/ci-aggregate` holds the required contexts open over the
# lanes a class stood down. A lane that no condition reads runs on every
# class; a lane a condition reads without a status function stands down on
# exactly the diffs nothing classified; an aggregate that waives a lane the
# class did not authorize turns a silent skip into a green required context.
# Each is a check nobody would see fail, which is why they are here.
#
# Four surfaces:
#   1. the selection: one row per class and path shape, asserting the whole
#      lane line, and the refusals beside them; then a `trivial` diff of a
#      path the Rust source reads, in a fixture checkout, with a control.
#   2. the names: the lanes the gates read, the lanes the changes job
#      publishes and the lanes ci-job-set selects are one set, compared by
#      name, and each aggregate, on its own, holds every job it needs to the
#      lane or event condition that job's own `if:` reads.
#   3. the job set: each gated job's own `if:` and the platform matrix's
#      `os:` expression, read out of the workflow and EVALUATED against a
#      selection and an event, with GitHub's implicit success() where a
#      condition carries no status function. A merge group runs the class
#      job set its pull request ran, less the two jobs held to the
#      pull-request event. A dead classifier runs every gated job and both
#      platform legs. The `CI` job needs every job but the aggregators and
#      runs on both gated events whatever its needs did. Must-fail arms plant
#      a lane condition that reads no selection, one that drops its status
#      function, one that ignores the class on a merge group, a matrix with
#      its arms swapped, a job dropped from CI's needs, CI without always(),
#      a lane dropped from one aggregate alone and an event-held job held to
#      another condition.
#   4. the aggregate: a lane the class authorized may skip; one it did not
#      is rejected, and so is a dead classifier, a job named twice and a
#      helper that is not there.
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which would resolve ROOT to the hook's
# repository instead of this one.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

ROOT="$(git rev-parse --show-toplevel)"
WORKFLOW="$ROOT/.github/workflows/skill-tests.yml"
# The workflow readers and the expression evaluator are the harness-ci
# package's, which its template suite reads a workflow with too.
# shellcheck source=../../skills/harness-ci/tests/lib/workflow.sh
. "$ROOT/skills/harness-ci/tests/lib/workflow.sh"
[ -f "$GH_EVAL" ] || { echo "missing $GH_EVAL" >&2; exit 1; }
JOB_SET="$ROOT/tools/ci-job-set"
AGGREGATE="$ROOT/tools/ci-aggregate"

mkdir -p "$ROOT/tmp"
TMP="$(mktemp -d "$ROOT/tmp/ci-class-job-set.XXXXXX")"
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { # DESC EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

# --- 1. The selection -------------------------------------------------------

# ci-job-set reads the Rust source of the checkout it runs in: this one,
# unless SELECT_IN names another; SELECT_WITH names a copy to run instead.
selection() { # CLASS DOCS_ONLY PATHS — the lane lines, blank-separated, or the refusal key
  local class="$1" docs="$2" paths="$3" out="$TMP/selection" status=0
  : >"$out"
  (cd "${SELECT_IN:-$ROOT}" && CHANGE_CLASS="$class" DOCS_ONLY="$docs" CHANGED_PATHS="$paths" \
    GITHUB_OUTPUT="$out" "${SELECT_WITH:-$JOB_SET}" 2>"$TMP/selection-err") || status=$?
  if [ "$status" -ne 0 ]; then
    printf 'exit=%s %s' "$status" \
      "$(sed -n 's/^ci-job-set: cause=//p' "$TMP/selection-err" | head -1)"
    return 0
  fi
  tr '\n' ' ' <"$out" | sed 's/ $//'
}

ALL_OFF="shell_shards=false macos_legs=false ui=false bot_instructions=false cargo_linux=false cargo_macos=false cargo_lint=false cargo_windows=false cargo_windows_check=false"
ALL_ON="shell_shards=true macos_legs=true ui=true bot_instructions=true cargo_linux=true cargo_macos=true cargo_lint=true cargo_windows=true cargo_windows_check=true"
# `render` and `trivial` run the one verify job.
VERIFY_ROW="shell_shards=false macos_legs=false ui=false bot_instructions=true cargo_linux=false cargo_macos=false cargo_lint=false cargo_windows=false cargo_windows_check=false"
# Every measured class runs the three Linux lanes. The platform lanes stand
# down only on an all-prose diff, the compile lanes where no build input
# changed, and ui off ui/.
PROSE_ROW="shell_shards=true macos_legs=false ui=false bot_instructions=true cargo_linux=true cargo_macos=false cargo_lint=false cargo_windows=false cargo_windows_check=false"
CODE_ROW="shell_shards=true macos_legs=true ui=false bot_instructions=true cargo_linux=true cargo_macos=true cargo_lint=false cargo_windows=true cargo_windows_check=false"
UI_ROW="shell_shards=true macos_legs=true ui=true bot_instructions=true cargo_linux=true cargo_macos=true cargo_lint=false cargo_windows=true cargo_windows_check=false"
BUILD_ROW="shell_shards=true macos_legs=true ui=false bot_instructions=true cargo_linux=true cargo_macos=true cargo_lint=true cargo_windows=true cargo_windows_check=true"

# CLASS|DOCS_ONLY|PATHS (blank-separated)|EXPECTED
selection_rows=0
while IFS='|' read -r class docs paths expected; do
  selection_rows=$((selection_rows + 1))
  check "selection: $class docs_only=$docs over '$paths'" "$expected" \
    "$(selection "$class" "$docs" "$(printf '%s\n' $paths)")"
done <<ROWS
render|false|.agents/skills/orch/SKILL.md .claude/skills/orch/SKILL.md|$VERIFY_ROW
trivial|true|docs/architecture/overview.md|$VERIFY_ROW
trivial|true|AGENTS.md|$VERIFY_ROW
standard|false|crates/core/src/lib.rs|$BUILD_ROW
micro|false|skills/orch/SKILL.md .agents/skills/orch/SKILL.md|$PROSE_ROW
small|false|crates/cli/src/main.rs|$BUILD_ROW
micro|false|ui/src/app.tsx|$UI_ROW
standard|false|skills/orch/scripts/lanes tools/guard|$CODE_ROW
standard|false|tools/ci-job-set.orig|$CODE_ROW
micro|false|install.sh|$CODE_ROW
micro|false|.gitattributes|$CODE_ROW
micro|false|skills/orch/scripts/lanes|$CODE_ROW
micro|true|docs/guide.md CHANGELOG.md|$PROSE_ROW
small|true|docs/guide.md CHANGELOG.md|$PROSE_ROW
standard|true|docs/guide.md CHANGELOG.md|$PROSE_ROW
standard|true|AGENTS.md|$PROSE_ROW
standard|true|CLAUDE.md|$PROSE_ROW
standard|true|GEMINI.md|$PROSE_ROW
standard|true|docs/legal/terms.md|$PROSE_ROW
trivial|true|docs/legal/terms.md|$PROSE_ROW
trivial|true|README.md|$PROSE_ROW
standard|false|docs/guide.md|$CODE_ROW
enormous|false|skills/orch/SKILL.md|exit=2 unknown-class class=enormous
micro|false||exit=2 class-without-paths class=micro
micro|maybe|skills/orch/SKILL.md|exit=2 invalid-docs-only value=maybe
ROWS
[ "$selection_rows" -ge 24 ] ||
  { echo "the selection table read $selection_rows rows" >&2; exit 1; }

# Each declared lane source runs every lane and each declared build name is a
# build input; both lists are read from the scripts and pinned here.
lane_sources() { # SCRIPT — a path per LANE_SOURCES alternative
  sed -n "s/^LANE_SOURCES='^(\(.*\))'\$/\1/p" "$1" | awk '{
    for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); d += (c == "(") - (c == ")")
      if (c == "|" && !d) { alt[++n] = cur; cur = "" } else cur = cur c }; alt[++n] = cur
    for (k = 1; k <= n; k++) { a = alt[k]; gsub(/\\/, "", a); sub(/\$$/, "", a); split("", opt)
      if (match(a, /\([^)]*\)/)) m = split(substr(a, RSTART + 1, RLENGTH - 2), opt, "|")
      else { m = 1; RSTART = length(a) + 1; RLENGTH = 0 }
      for (j = 1; j <= m; j++) print substr(a, 1, RSTART - 1) opt[j] substr(a, RSTART + RLENGTH) (a ~ /\/$/ ? "x" : "") } }'
}
build_names() { # SCRIPT — the names its build list declares
  awk '/^build=\$\(printf/ { on = 1; sub(/.*%s\\n. /, "") } on { last = /\)$/; gsub(/[\\)]/, ""); print; if (last) exit }' "$1" | tr -s ' ' '\n' | grep .
}
SOURCES=".github/workflows/x .github/actions/x tools/ci-job-set tools/ci-aggregate tools/rust-reads"
NAMES="crates Cargo.toml Cargo.lock rust-toolchain rust-toolchain.toml .cargo clippy.toml .clippy.toml rustfmt.toml .rustfmt.toml"
pins() { echo "$(echo $(lane_sources "$1"))|$(echo $(build_names "$2"))"; } # JOB-SET READER
check "the declared lists are the pinned sets" "$SOURCES|$NAMES" "$(pins "$JOB_SET" "$ROOT/tools/rust-reads")"
sources="$(lane_sources "$JOB_SET")" names="$(build_names "$ROOT/tools/rust-reads")"
while IFS= read -r p; do check "lane source $p runs every lane" "$ALL_ON" "$(selection standard false "$p")"; done <<<"$sources"
while IFS= read -r p; do check "build name $p is a build input" "$BUILD_ROW" "$(selection micro false "$p")"; done <<<"$names"
mkdir -p "$TMP/member/tools"
sed 's/(\(ci-job-set.\)ci-aggregate/(\1nothing/' "$JOB_SET" >"$TMP/member/tools/ci-job-set"
sed 's/ \.cargo \\$/ \\/' "$ROOT/tools/rust-reads" >"$TMP/member/tools/rust-reads"
chmod +x "$TMP/member/tools/ci-job-set" "$TMP/member/tools/rust-reads"
check "control: a copy without a member fails each pin" "${SOURCES/ci-aggregate/nothing}|$(echo ${NAMES/.cargo /})" \
  "$(pins "$TMP/member/tools/ci-job-set" "$TMP/member/tools/rust-reads")"
for row in "standard tools/ci-aggregate" "micro .cargo"; do
  check "control: copies without the member $row run it as no lane source or build input" "$CODE_ROW" \
    "$(SELECT_WITH="$TMP/member/tools/ci-job-set" selection ${row% *} false "${row#* }")"
done

# A row that forgets a lane is refused before any lane reads it. macos_legs is
# the lane no aggregate holds, so this refusal is what keeps a forgotten
# platform lane from collapsing the matrix in silence. The copy drops one lane
# from the render row.
mkdir -p "$TMP/forgot/tools"
forgot="$TMP/forgot/tools/ci-job-set"
[ "$(grep -c 'cargo_lint=false cargo_windows=false cargo_windows_check=false$' "$JOB_SET")" -eq 1 ] ||
  { echo "the render row is no longer one line in $JOB_SET" >&2; exit 1; }
awk '
  /cargo_lint=false cargo_windows=false cargo_windows_check=false$/ {
    sub(/ cargo_windows_check=false$/, "")
  }
  { print }
' "$JOB_SET" >"$forgot"
chmod +x "$forgot"
! cmp -s "$JOB_SET" "$forgot" || { echo "the forgotten-lane copy changed nothing" >&2; exit 1; }
forgot_status=0
CHANGE_CLASS=render DOCS_ONLY=false CHANGED_PATHS=CLAUDE.md GITHUB_OUTPUT="$TMP/forgot-out" \
  "$forgot" 2>"$TMP/forgot-err" || forgot_status=$?
check "a row that forgets a lane is refused" \
  "exit=2 lane-unselected lane=cargo_windows_check" \
  "exit=$forgot_status $(sed -n 's/^ci-job-set: cause=//p' "$TMP/forgot-err")"

# A `trivial` diff changing a path tools/rust-reads names takes the measured
# row. The fixture crate reads docs/a.md and assets/x.json through
# include_str!, docs/legal and tools/x through a manifest chain, and the
# checkout root, whose `.` row matches nothing. What each source shape reads
# is tools/tests/rust-reads.test.sh's.
READ_WORLD="$TMP/read-world"
mkdir -p "$READ_WORLD/crates/demo/src"
printf '[package]\nname = "demo"\n' >"$READ_WORLD/crates/demo/Cargo.toml"
cat >"$READ_WORLD/crates/demo/src/lib.rs" <<'RS'
const A: &str = include_str!("../../../docs/a.md");
const X: &str = include_str!("../../../assets/x.json");
fn tool() { read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tools/x")); }
fn legal(name: &str) -> PathBuf { PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../docs/legal").join(name) }
fn root() -> PathBuf { Path::new(env!("CARGO_MANIFEST_DIR")).join("../..") }
RS
# CLASS|PATHS (blank-separated)|EXPECTED, every row docs-only.
READ_ROWS="trivial|docs/a.md|$PROSE_ROW
trivial|docs/legal/terms.md|$PROSE_ROW
trivial|docs/other.md docs/legal/privacy.md|$PROSE_ROW
trivial|docs/other.md|$VERIFY_ROW
trivial|docs/legalese.md|$VERIFY_ROW
render|docs/a.md|$VERIFY_ROW"
read_rows=0
while IFS='|' read -r class paths expected; do
  read_rows=$((read_rows + 1))
  check "read selection: $class over '$paths'" "$expected" \
    "$(SELECT_IN="$READ_WORLD" selection "$class" true "$(printf '%s\n' $paths)")"
done <<<"$READ_ROWS"
[ "$read_rows" -ge 6 ] || { echo "the read table read $read_rows rows" >&2; exit 1; }
mkdir -p "$TMP/no-crates"
check "a read set rust-reads cannot derive is refused" "exit=2 rust-reads-failed" \
  "$(SELECT_IN="$TMP/no-crates" selection trivial true docs/a.md)"
check "and on a measured diff, whose compile lanes it gates" "exit=2 rust-reads-failed" \
  "$(SELECT_IN="$TMP/no-crates" selection micro true docs/a.md)"
# A build input is a non-prose path under a build or include row, not a read.
check "an included file other than prose is a build input" "$BUILD_ROW" \
  "$(SELECT_IN="$READ_WORLD" selection micro false assets/x.json)"
check "a file the Rust source reads at run time is no build input" "$CODE_ROW" \
  "$(SELECT_IN="$READ_WORLD" selection micro false tools/x)"
# The platform lanes run on a standard diff that is not documentation alone,
# prose included; the control drops that rule.
mkdir -p "$TMP/standard/tools"
cp "$ROOT/tools/rust-reads" "$TMP/standard/tools/rust-reads"
sed '/\[ "\$CHANGE_CLASS:\$DOCS_ONLY" != standard:false \] /d' "$JOB_SET" >"$TMP/standard/tools/ci-job-set"
chmod +x "$TMP/standard/tools/ci-job-set"
[ "$(SELECT_WITH="$TMP/standard/tools/ci-job-set" selection standard false docs/guide.md)" = "$PROSE_ROW" ] &&
  ok "control: without the standard rule a standard prose diff stands the platform lanes down" ||
  bad "control: without the standard rule a standard prose diff stands the platform lanes down"
# EDIT|CLASS|PATHS|EXPECTED — a copy with that rule removed answers the row
# other than EXPECTED.
mkdir -p "$TMP/rule/tools"
cp "$ROOT/tools/rust-reads" "$TMP/rule/tools/rust-reads"
while IFS='|' read -r edit class paths expected; do
  sed "$edit" "$JOB_SET" >"$TMP/rule/tools/ci-job-set"
  chmod +x "$TMP/rule/tools/ci-job-set"
  if cmp -s "$JOB_SET" "$TMP/rule/tools/ci-job-set"; then
    bad "control: the edit changed nothing in a ci-job-set copy: $edit"
    continue
  fi
  got="$(SELECT_IN="$READ_WORLD" SELECT_WITH="$TMP/rule/tools/ci-job-set" selection "$class" true "$paths")"
  [ "$got" != "$expected" ] && ok "control: $edit reddens $class over $paths" ||
    bad "control: $edit reddens $class over $paths (still '$got')"
done <<CONTROLS
s/row=trivial-read ;;/row=trivial ;;/|trivial|docs/a.md|$PROSE_ROW
s/index(path, read\[r\] "\/") != 1/index(path, read[r]) != 1/|trivial|docs/legalese.md|$VERIFY_ROW
s/if (kind\[r\] != "manifest" .*) build = 1/build = 1/|micro|docs/a.md|$PROSE_ROW
s/kind\[r\] != "manifest" .. //|micro|tools/x|$CODE_ROW
s/if any "\$LANE_SOURCES"; then/if false; then/|standard|.github/workflows/skill-tests.yml|$ALL_ON
s/ci-aggregate.rust-reads)\$)/ci-aggregate.rust-reads))/|standard|tools/ci-job-set.orig|$CODE_ROW
s/any '^ui\/' .. uitree=true/uitree=true/|micro|docs/a.md|$PROSE_ROW
CONTROLS

# --- 2. The names -----------------------------------------------------------
# Each reader is extracted with an anchored pattern: a name is the whole run
# of name characters after `needs.changes.outputs.`, so a misspelt name is a
# different member of the set, never a substring match of the right one.

OUTPUT_NAME='needs\.changes\.outputs\.[a-z_]+'

# The platform matrix's `os:` expression, the `${{ }}` stripped.
matrix_expr() { # WORKFLOW
  sed -n 's/^        os: \${{ \(.*\) }}$/\1/p' "$1"
}

# `LANE:JOB` for every job whose own condition reads a lane.
gate_pairs() { # WORKFLOW
  job_ifs "$1" | while IFS="$(printf '\t')" read -r job expr; do
    printf '%s\n' "$expr" | grep -oE "$OUTPUT_NAME" |
      sed "s/^needs\\.changes\\.outputs\\.//; s/\$/:$job/" || true
  done | LC_ALL=C sort -u
}

# Every lane a gate reads: the job conditions and the platform matrix.
lanes_read() { # WORKFLOW
  { gate_pairs "$1" | sed 's/:.*//'
    matrix_expr "$1" | grep -oE "$OUTPUT_NAME" | sed 's/^needs\.changes\.outputs\.//' || true
  } | LC_ALL=C sort -u
}

# `NAME SOURCE` for every changes-job output the select step publishes.
published_map() { # WORKFLOW
  awk '
    /^  changes:/ { in_job = 1; next }
    in_job && /^  [A-Za-z0-9_-]+:/ { in_job = 0 }
    in_job && /^    outputs:/ { in_outputs = 1; next }
    in_outputs && !/^      / { in_outputs = 0 }
    in_outputs && match($0, /^      [a-z_]+: \$\{\{ steps\.select\.outputs\.[a-z_]+ \}\}$/) {
      name = $1; sub(/:$/, "", name)
      source = $0; sub(/.*steps\.select\.outputs\./, "", source); sub(/ .*/, "", source)
      print name " " source
    }
  ' "$1"
}

# `AGGREGATE<tab>JOB<tab>EXPR` for every `--lane "$VAR:JOB"` an aggregate
# passes, VAR resolved through that same job's `VAR: ${{ EXPR }}` entry, and
# EXPR empty where it resolves to none. AGGREGATE, when named, keeps that
# job's lanes alone.
aggregate_lanes() { # WORKFLOW [AGGREGATE]
  AGG="${2:-}" awk '
    /^  [A-Za-z0-9_-]+:/ { agg = $1; sub(/:$/, "", agg); split("", var) }
    match($0, /^          [A-Z_]+: \$\{\{ .* \}\}$/) {
      name = $1; sub(/:$/, "", name)
      expr = $0; sub(/^[^{]*\{\{ /, "", expr); sub(/ \}\}$/, "", expr)
      var[name] = expr
    }
    match($0, /--lane "\$[A-Z_]+:[a-z0-9-]+"/) {
      pair = substr($0, RSTART + 9, RLENGTH - 10)
      name = pair; sub(/:.*/, "", name)
      job = pair; sub(/^[^:]*:/, "", job)
      if (ENVIRON["AGG"] == "" || agg == ENVIRON["AGG"]) print agg "\t" job "\t" ((name in var) ? var[name] : "")
    }
  ' "$1" | LC_ALL=C sort -u
}
PUBLISHED_LANE='^needs\.changes\.outputs\.[a-z_]+$'
# `LANE:JOB` for each lane held to a published selection, and `?:JOB` for one
# whose selection resolves to nothing, which matches no lane.
aggregate_pairs() { # WORKFLOW [AGGREGATE]
  aggregate_lanes "$@" | LANE="$PUBLISHED_LANE" awk -F '\t' '
    $3 == "" { print "?:" $2; next }
    $3 ~ ENVIRON["LANE"] { sub(/^needs\.changes\.outputs\./, "", $3); print $3 ":" $2 }
  ' | LC_ALL=C sort -u
}
# `JOB<tab>EXPR` for each lane held to anything but a published selection:
# the event conditions a job is held to.
aggregate_events() { # WORKFLOW [AGGREGATE]
  aggregate_lanes "$@" | LANE="$PUBLISHED_LANE" awk -F '\t' '$3 != "" && $3 !~ ENVIRON["LANE"] { print $2 "\t" $3 }' |
    LC_ALL=C sort -u
}
# `missing=` and `extra=` of ACTUAL against EXPECTED, each a line-per-member set.
set_gap() { # EXPECTED ACTUAL
  printf 'missing=%s extra=%s' \
    "$(comm -23 <(printf '%s\n' "$1" | grep . | LC_ALL=C sort) <(printf '%s\n' "$2" | grep . | LC_ALL=C sort) | tr '\n' ' ' | sed 's/ $//')" \
    "$(comm -13 <(printf '%s\n' "$1" | grep . | LC_ALL=C sort) <(printf '%s\n' "$2" | grep . | LC_ALL=C sort) | tr '\n' ' ' | sed 's/ $//')"
}
CI_JOB="$(jobs_named "$WORKFLOW" CI)"
aggregators() { # WORKFLOW — every job whose script calls tools/ci-aggregate
  awk '
    /^jobs:/ { in_jobs = 1; next }
    !in_jobs { next }
    /^  [A-Za-z0-9_-]+:/ { job = $1; sub(/:$/, "", job); next }
    /^ +tools\/ci-aggregate --/ { print job }
  ' "$1" | LC_ALL=C sort -u
}

PUBLISHED_BY_SCRIPT="$(selection standard false 'crates/core/src/lib.rs' |
  tr ' ' '\n' | sed 's/=.*//' | LC_ALL=C sort)"
[ "$(printf '%s\n' "$PUBLISHED_BY_SCRIPT" | grep -c .)" -gt 0 ] ||
  { echo "ci-job-set published no lane, so the extractor is broken" >&2; exit 1; }
check "the changes job publishes exactly the lanes ci-job-set selects" \
  "$PUBLISHED_BY_SCRIPT" "$(published_map "$WORKFLOW" | awk '{ print $1 }' | LC_ALL=C sort)"
check "each published lane is the select step's line of the same name" "" \
  "$(published_map "$WORKFLOW" | awk '$1 != $2')"
check "the gates read exactly the lanes ci-job-set selects" \
  "$PUBLISHED_BY_SCRIPT" "$(lanes_read "$WORKFLOW")"
GATE_PAIRS="$(gate_pairs "$WORKFLOW")"
[ "$(printf '%s\n' "$GATE_PAIRS" | grep -c .)" -gt 0 ] ||
  { echo "no gated job read out of $WORKFLOW, so the extractor is broken" >&2; exit 1; }

# Each aggregate, on its own, holds every gated job it needs to the lane that
# job's own condition reads, and every job it needs whose condition stands it
# down on a gated event to that condition, spelled as the job spells it. The
# aggregates repeat each other's lanes, so a comparison over their union
# would hide one aggregate's omission behind another's copy. A needed job
# with no lane is event-held where its own condition evaluates false on
# pull_request or merge_group; a condition the evaluator refuses prints its
# refusal into the gap.
aggregate_gap() { # WORKFLOW AGGREGATE — `lanes: missing= extra= events: missing= extra=`
  local wf="$1" agg="$2" needs job expr pr group held=""
  needs="$(job_needs "$wf" | awk -F '\t' -v j="$agg" '$1 == j { print $2 }' | tr ',' '\n' | grep .)" || needs=""
  gate_pairs "$wf" >"$TMP/gap-gates"
  job_ifs "$wf" >"$TMP/gap-ifs"
  while IFS= read -r job; do
    grep -q ":$job\$" "$TMP/gap-gates" && continue
    expr="$(awk -F '\t' -v j="$job" '$1 == j { print $2 }' "$TMP/gap-ifs")"
    [ -n "$expr" ] || continue
    pr="$(gh_eval value '{"github":{"event_name":"pull_request"}}' "$expr")"
    group="$(gh_eval value '{"github":{"event_name":"merge_group"}}' "$expr")"
    case "$pr $group" in
      "true true") ;;
      "true false" | "false true" | "false false") held="$held$(printf '%s\t%s' "$job" "$expr")
" ;;
      *) held="$held$(printf '%s\t%s' "$job" "refused: $pr $group")
" ;;
    esac
  done <<<"$needs"
  printf 'lanes: %s events: %s' \
    "$(set_gap "$(printf '%s\n' "$needs" | while IFS= read -r job; do grep ":$job\$" "$TMP/gap-gates" || true; done)" \
      "$(aggregate_pairs "$wf" "$agg")")" \
    "$(set_gap "$held" "$(aggregate_events "$wf" "$agg")" | tr '\t' '=')"
}
AGGREGATE_ROWS=0
for agg in $(aggregators "$WORKFLOW"); do
  AGGREGATE_ROWS=$((AGGREGATE_ROWS + 1))
  check "$agg holds each job it needs to the selection its own condition reads" \
    "lanes: missing= extra= events: missing= extra=" "$(aggregate_gap "$WORKFLOW" "$agg")"
done
[ "$AGGREGATE_ROWS" -ge 4 ] || { echo "the aggregate table read $AGGREGATE_ROWS rows" >&2; exit 1; }
# The event-held set, derived above, holds the two diff checks CI names.
EVENT_HELD="$(aggregate_events "$WORKFLOW" | cut -f1 | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')"
check "the aggregates hold the two diff checks to an event" "markdown preflight" "$EVENT_HELD"

# --- 3. The job set ---------------------------------------------------------
# gh-eval.py's header names the expression forms it covers and refuses the
# rest.

# The context a gated job's condition reads: the event, and the changes job's
# result with the outputs its published map names out of a selection, or none
# where it did not succeed.
context_json() { # EVENT RESULT SELECTION MAP_FILE
  local outputs='{}'
  if [ "$2" = success ]; then
    outputs="$(printf '%s\n' $3 | jq -Rn --rawfile map "$4" '
      ([inputs | select(length > 0) | split("=") | {key: .[0], value: .[1]}] | from_entries) as $chosen
      | [$map | split("\n")[] | select(length > 0) | split(" ")
         | select($chosen[.[1]] != null) | {key: .[0], value: $chosen[.[1]]}] | from_entries')" ||
      { echo "could not build the outputs of '$3'" >&2; exit 1; }
  fi
  jq -cn --arg event "$1" --arg result "$2" --argjson outputs "$outputs" \
    '{github: {event_name: $event}, needs: {changes: {result: $result, outputs: $outputs}}}'
}

# The jobs a class or an event stands down or runs: every job whose own
# condition reads a lane, and every job an aggregate holds, since a job an
# aggregate holds whose condition reads nothing runs on every class.
gated_jobs() { # WORKFLOW
  { gate_pairs "$1" | sed 's/^[^:]*://'; aggregate_lanes "$1" | cut -f2; } | LC_ALL=C sort -u
}

running() { # WORKFLOW SELECTION [RESULT] [EVENT] — the gated jobs that run, sorted and spaced
  local wf="$1" sel="$2" result="${3:-success}" event="${4:-pull_request}" map="$TMP/published-map" job expr
  published_map "$wf" >"$map"
  gated_jobs "$wf" >"$TMP/gated"
  job_needs "$wf" >"$TMP/needs"
  job_ifs "$wf" | while IFS="$(printf '\t')" read -r job expr; do
    grep -qxF -- "$job" "$TMP/gated" &&
      printf '%s\t%s\t%s\n' "$job" "$(awk -F '\t' -v j="$job" '$1 == j { print $2 }' "$TMP/needs")" "$expr"
  done >"$TMP/gated-ifs" || true
  gh_eval jobs "$(context_json "$event" "$result" "$sel" "$map")" <"$TMP/gated-ifs" |
    LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'
}

legs() { # WORKFLOW SELECTION [RESULT] — the platform legs the matrix expands to
  local wf="$1" sel="$2" result="${3:-success}" map="$TMP/published-map" expr
  published_map "$wf" >"$map"
  expr="$(matrix_expr "$wf")"
  [ -n "$expr" ] || { printf 'no-matrix-expression'; return 0; }
  gh_eval value "$(context_json pull_request "$result" "$sel" "$map")" "$expr"
}

EVERY_GATED="bot-instructions cargo-check-windows cargo-lint cargo-linux cargo-macos cargo-tests-windows markdown preflight skill-suites-shard ui-tests"
# What a merge group runs of it: every lane, without the two pull-request diff
# checks.
EVERY_GROUP_LANE="bot-instructions cargo-check-windows cargo-lint cargo-linux cargo-macos cargo-tests-windows skill-suites-shard ui-tests"
check "the gated set is read out of the workflow" "$EVERY_GATED" \
  "$(gated_jobs "$WORKFLOW" | tr '\n' ' ' | sed 's/ $//')"

one_skill="$(selection micro false 'skills/orch/SKILL.md
.agents/skills/orch/SKILL.md')"
# A standard diff of product code, the full battery a pull request of that
# class runs.
standard_code="$(selection standard false 'crates/core/src/lib.rs')"
# EVENT|SELECTION|EXPECTED JOBS. A merge group runs the class job set its pull
# request ran, the two pull-request diff checks aside: a `render` group runs
# the one verify job and a standard group every lane its class selects.
job_rows=0
while IFS='|' read -r event sel expected; do
  job_rows=$((job_rows + 1))
  check "jobs on $event under '$sel'" "$expected" "$(running "$WORKFLOW" "$sel" success "$event")"
done <<ROWS
pull_request|$VERIFY_ROW|bot-instructions markdown preflight
merge_group|$VERIFY_ROW|bot-instructions
pull_request|$ALL_ON|$EVERY_GATED
merge_group|$ALL_ON|$EVERY_GROUP_LANE
pull_request|$one_skill|bot-instructions cargo-linux markdown preflight skill-suites-shard
merge_group|$one_skill|bot-instructions cargo-linux skill-suites-shard
pull_request|$CODE_ROW|bot-instructions cargo-linux cargo-macos cargo-tests-windows markdown preflight skill-suites-shard
merge_group|$CODE_ROW|bot-instructions cargo-linux cargo-macos cargo-tests-windows skill-suites-shard
pull_request|$standard_code|bot-instructions cargo-check-windows cargo-lint cargo-linux cargo-macos cargo-tests-windows markdown preflight skill-suites-shard
merge_group|$standard_code|bot-instructions cargo-check-windows cargo-lint cargo-linux cargo-macos cargo-tests-windows skill-suites-shard
ROWS
[ "$job_rows" -ge 10 ] || { echo "the job table read $job_rows rows" >&2; exit 1; }

# The same property over every selection the table names: what a merge group
# runs is what its pull request ran less the event-held jobs.
without_event_held() { # JOBS — the jobs, spaced, with every event-held one dropped
  local job out=""
  for job in $1; do
    case " $EVENT_HELD " in *" $job "*) ;; *) out="$out $job" ;; esac
  done
  printf '%s' "${out# }"
}
for sel in "$VERIFY_ROW" "$ALL_ON" "$one_skill" "$CODE_ROW" "$UI_ROW" "$PROSE_ROW" "$standard_code"; do
  check "a merge group runs its pull request's class job set under '$sel'" \
    "$(without_event_held "$(running "$WORKFLOW" "$sel" success pull_request)")" \
    "$(running "$WORKFLOW" "$sel" success merge_group)"
done

# A classifier that died published nothing. Every gated job runs, which is
# what each condition's status function and result term are for.
check "a dead classifier runs every gated job" "$EVERY_GATED" \
  "$(running "$WORKFLOW" "$ALL_OFF" failure)"

check "the matrix runs both legs where the class selects them" \
  '["ubuntu-latest","macos-latest"]' "$(legs "$WORKFLOW" "$ALL_ON")"
check "the matrix runs the Linux leg alone where the class drops macOS" \
  '["ubuntu-latest"]' "$(legs "$WORKFLOW" "$one_skill")"
check "the matrix runs both legs when nothing classified" \
  '["ubuntu-latest","macos-latest"]' "$(legs "$WORKFLOW" "$ALL_OFF" failure)"

# The document byte ceilings and the work-marker scan run in the job a
# `render` or `trivial` diff runs, and in no other, so every class that runs
# any gated job runs both scans. Each `run:` line is read with the job it
# sits in. The job a `render` diff runs is read off a merge group, where no
# job held to the pull-request event runs beside it.
job_of_run() { # WORKFLOW COMMAND — the jobs whose `run:` line names it, sorted and spaced
  COMMAND="$2" awk '
    /^jobs:/ { in_jobs = 1; next }
    !in_jobs { next }
    /^  [A-Za-z0-9_-]+:/ { job = $1; sub(/:$/, "", job); next }
    /^ +run: / && index($0, ENVIRON["COMMAND"]) > 0 { print job }
  ' "$1" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'
}
VERIFY_JOBS="$(running "$WORKFLOW" "$VERIFY_ROW" success merge_group)"
[ -n "$VERIFY_JOBS" ] || { echo "the verify row runs no job, so the extractor is broken" >&2; exit 1; }
for scan in skills/doc-limits/scripts/doc-limits skills/commit-guards/scripts/todo-ban; do
  check "$scan runs in the verify job alone" "$VERIFY_JOBS" "$(job_of_run "$WORKFLOW" "$scan")"
done

# --- 3a. The one context ---------------------------------------------------
# `CI` is the context the organization ruleset requires beside `Review gate`.
# Every job reports into it but the aggregators, which run tools/ci-aggregate
# as it does; it runs on both gated events whatever its needs did, and the
# classifier it reads runs on both.

ci_needs_gap() { # WORKFLOW — `missing=` and `extra=` against every job but the aggregators
  local wf="$1" ci
  ci="$(jobs_named "$wf" CI)"
  set_gap "$(job_needs "$wf" | cut -f1 | LC_ALL=C sort | comm -23 - <(aggregators "$wf"))" \
    "$(job_needs "$wf" | awk -F '\t' -v j="$ci" '$1 == j { print $2 }' | tr ',' '\n')"
}
check "one job is named CI" "ci" "$(jobs_named "$WORKFLOW" CI | tr '\n' ' ' | sed 's/ $//')"
AGGREGATORS="$(aggregators "$WORKFLOW" | tr '\n' ' ' | sed 's/ $//')"
check "the aggregators are read out of the workflow" "cargo-tests cargo-tests-macos ci skill-suites" "$AGGREGATORS"
check "CI needs every job but the aggregators" "missing= extra=" "$(ci_needs_gap "$WORKFLOW")"
# EVENT|RESULT|RUNS
ci_rows=0
while IFS='|' read -r event result runs; do
  ci_rows=$((ci_rows + 1))
  check "CI runs on $event with its needs at $result: $runs" "$runs" "$(ci_runs "$WORKFLOW" "$event" "$result")"
done <<ROWS
pull_request|success|yes
pull_request|failure|yes
merge_group|failure|yes
merge_group|skipped|yes
push|success|no
ROWS
[ "$ci_rows" -ge 5 ] || { echo "the CI table read $ci_rows rows" >&2; exit 1; }
# The classifier every lane and CI read runs on both gated events.
check "the workflow runs on both gated events" "merge_group pull_request push" \
  "$(triggers "$WORKFLOW" | tr '\n' ' ' | sed 's/ $//')"
changes_if="$(job_ifs "$WORKFLOW" | awk -F '\t' '$1 == "changes" { print $2 }')"
for event in pull_request merge_group; do
  check "the changes job classifies on $event" "true" \
    "$(gh_eval value "$(jq -cn --arg e "$event" '{github: {event_name: $e}}')" "$changes_if")"
done

# --- 3b. Must-fail controls -------------------------------------------------

# The pre-patch shape of the macOS cargo lane: gated on the event alone. It
# runs on the one-skill row, which is the full battery the narrowing exists
# to avoid.
plant "$WORKFLOW" "!cancelled() && (github.event_name == 'push' || needs.changes.result != 'success' || needs.changes.outputs.cargo_macos == 'true')" \
  "!cancelled()" "$TMP/wf-ungated.yml"
case " $(running "$TMP/wf-ungated.yml" "$one_skill") " in
  *" cargo-macos "*) ok "must-fail: a lane condition reading no selection runs on the one-skill row" ;;
  *) bad "must-fail: an ungated macOS cargo lane still reads as gated" ;;
esac

# A condition without its status function keeps GitHub's implicit success()
# and stands its lane down on exactly the run nothing classified.
plant "$WORKFLOW" "!cancelled() && github.event_name != 'push' && (needs.changes.result != 'success' || needs.changes.outputs.ui == 'true')" \
  "github.event_name != 'push' && (needs.changes.result != 'success' || needs.changes.outputs.ui == 'true')" \
  "$TMP/wf-no-status.yml"
case " $(running "$TMP/wf-no-status.yml" "$ALL_OFF" failure) " in
  *" ui-tests "*) bad "must-fail: a condition with no status function still runs under a dead classifier" ;;
  *) ok "must-fail: a condition with no status function stands down under a dead classifier" ;;
esac

# The matrix with its two arms swapped runs macOS exactly where the class
# dropped it.
plant "$WORKFLOW" "'[\"ubuntu-latest\", \"macos-latest\"]' || '[\"ubuntu-latest\"]'" \
  "'[\"ubuntu-latest\"]' || '[\"ubuntu-latest\", \"macos-latest\"]'" "$TMP/wf-swapped.yml"
check "must-fail: a matrix with its arms swapped expands the wrong legs" \
  '["ubuntu-latest","macos-latest"]' "$(legs "$TMP/wf-swapped.yml" "$one_skill")"

# The doc-limits step moved, not deleted, into the shell shards: the scan
# still runs, but not on the classes that run no shard.
awk '
  /^  [A-Za-z0-9_-]+:/ { job = $1; sub(/:$/, "", job) }
  job == "bot-instructions" && $0 == "      - name: doc-limits (document byte ceilings)" {
    skip = 1; moved++; next
  }
  skip && /^        / { next }
  { skip = 0; print }
  job == "skill-suites-shard" && $0 == "    steps:" {
    print "      - name: doc-limits (document byte ceilings)"
    print "        run: skills/doc-limits/scripts/doc-limits"
    inserted++
  }
  END { if (moved != 1 || inserted != 1) exit 2 }
' "$WORKFLOW" >"$TMP/wf-moved-scan.yml" ||
  { echo "the doc-limits step could not be moved in a copy" >&2; exit 1; }
check "must-fail: a doc-limits step moved to the shell shards is reported there" \
  "skill-suites-shard" \
  "$(job_of_run "$TMP/wf-moved-scan.yml" skills/doc-limits/scripts/doc-limits)"

# A lane that ignores the class on a merge group runs in a render group,
# which is the full battery the queue pass exists to avoid.
plant "$WORKFLOW" "github.event_name == 'push' || needs.changes.result != 'success' || needs.changes.outputs.cargo_linux == 'true'" \
  "github.event_name == 'push' || github.event_name == 'merge_group' || needs.changes.result != 'success' || needs.changes.outputs.cargo_linux == 'true'" \
  "$TMP/wf-group-ungated.yml"
check "must-fail: a lane ignoring the class on merge groups runs in a render group" \
  "bot-instructions cargo-linux" "$(running "$TMP/wf-group-ungated.yml" "$VERIFY_ROW" success merge_group)"

# A job CI does not need reports into no required context.
plant "$WORKFLOW" "needs: [changes, bot-instructions, skill-suites-shard," "needs: [changes, skill-suites-shard," "$TMP/wf-ci-short.yml"
check "must-fail: a job dropped from CI's needs is named" "missing=bot-instructions extra=" \
  "$(ci_needs_gap "$TMP/wf-ci-short.yml")"

# A lane dropped from one aggregate alone, while another aggregate still
# passes it, is named on that aggregate: CI, and a per-repository aggregator.
# AGGREGATE|LANE LINE|GAP
while IFS='|' read -r agg line gap; do
  plant "$WORKFLOW" "$line" '' "$TMP/wf-lane-$agg.yml" "$agg"
  check "must-fail: a lane dropped from $agg alone is named" "$gap" "$(aggregate_gap "$TMP/wf-lane-$agg.yml" "$agg")"
done <<'ROWS'
ci|--lane "$UI:ui-tests"|lanes: missing=ui:ui-tests extra= events: missing= extra=
cargo-tests|--lane "$CARGO_LINT:cargo-lint"|lanes: missing=cargo_lint:cargo-lint extra= events: missing= extra=
ROWS

# Without always(), GitHub's implicit success() skips CI on a failed need, and
# a skipped required context satisfies the ruleset.
plant "$WORKFLOW" "    if: always() && github.event_name != 'push'" "    if: github.event_name != 'push'" \
  "$TMP/wf-ci-no-always.yml" "$CI_JOB"
check "must-fail: CI without always() does not run on a failed need" "no" \
  "$(ci_runs "$TMP/wf-ci-no-always.yml" merge_group failure)"

# An event-held job held to another condition than its own.
plant "$WORKFLOW" "PULL_REQUEST: \${{ github.event_name == 'pull_request' }}" "PULL_REQUEST: \${{ github.event_name != 'push' }}" \
  "$TMP/wf-event-drift.yml"
check "must-fail: an event-held job held to another condition is named" \
  "lanes: missing= extra= events: missing=markdown=github.event_name == 'pull_request' preflight=github.event_name == 'pull_request' extra=markdown=github.event_name != 'push' preflight=github.event_name != 'push'" \
  "$(aggregate_gap "$TMP/wf-event-drift.yml" "$CI_JOB")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
