#!/usr/bin/env bash
# What `.github/workflows/skill-tests.yml` runs is keyed to the change class,
# and the keying is in three places that have to agree: `tools/ci-job-set`
# turns a class into one line per lane and a list of shell shards, each job's
# `if:` and the shard matrix read those lines, and `tools/ci-aggregate` holds the required contexts open over the
# lanes a class stood down. A lane that no condition reads runs on every
# class; a lane a condition reads without a status function stands down on
# exactly the diffs nothing classified; an aggregate that waives a lane the
# class did not authorize turns a silent skip into a green required context.
# Each is a check nobody would see fail, which is why they are here.
#
# Four surfaces:
#   1. the selection: one row per class and path shape, asserting the whole
#      lane line and shard list, and the refusals beside them; a control per
#      shard-selection rule; then a `trivial` diff of a path the Rust source
#      reads, and a dependency list the reader cannot take, in fixture
#      checkouts.
#   2. the names: the lanes the gates read, the lanes the changes job
#      publishes and the lanes ci-job-set selects are one set, compared by
#      name, and each aggregate, on its own, holds every job it needs to the
#      lane or event condition that job's own `if:` reads.
#   3. the job set: each gated job's own `if:` and the shard matrix's `os:`
#      and `shard:` expressions, read out of the workflow and EVALUATED
#      against a selection and an event, with GitHub's implicit success() where a
#      condition carries no status function. A merge group runs the class
#      job set its pull request ran, less the two jobs held to the
#      pull-request event. The macOS legs run on a pull request only where
#      the selection says a lane source changed. A dead classifier runs every
#      gated job, both platform legs and the whole shard roster. A pull
#      request's run is cancelled by its next push; no other run is. The `CI` job needs every job but the aggregators and
#      runs on both gated events whatever its needs did. Must-fail arms plant
#      a lane condition that reads no selection, one that drops its status
#      function, one that ignores the class on a merge group, a matrix with
#      its arms swapped, one ignoring the event, a shard key reading no
#      selection, a cancel held to no event, a job dropped from CI's needs, CI without always(),
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

# The whole shard roster, in the matrix's order.
ROSTER='["review-gate","orch-terminal","orch-oversee","orch-oversee-succeed","orch-state","orch-rest","guards-scans","guards-commit","guards-tools","linear","worktree","rest","node","pi-claude-bridge"]'
ORCH='"orch-terminal","orch-oversee","orch-oversee-succeed","orch-state","orch-rest"'
ALL_OFF="shell_shards=false macos_legs=false macos_pull_request=false ui=false bot_instructions=false cargo_linux=false cargo_macos=false cargo_lint=false cargo_windows=false cargo_windows_check=false shards=[]"
ALL_ON="shell_shards=true macos_legs=true macos_pull_request=true ui=true bot_instructions=true cargo_linux=true cargo_macos=true cargo_lint=true cargo_windows=true cargo_windows_check=true shards=$ROSTER"
# `render` and `trivial` run the one verify job.
VERIFY_ROW="shell_shards=false macos_legs=false macos_pull_request=false ui=false bot_instructions=true cargo_linux=false cargo_macos=false cargo_lint=false cargo_windows=false cargo_windows_check=false shards=[]"
# Every measured class runs cargo_linux and bot_instructions. The shell
# shards run per package, the platform lanes stand down only on an all-prose
# diff, the macOS legs also where no shard runs, the compile lanes where no
# build input changed, and ui off ui/.
measured() { # SHELL MACOS MACOS_PR UI PLATFORM BUILD SHARDS — one measured row
  printf 'shell_shards=%s macos_legs=%s macos_pull_request=%s ui=%s bot_instructions=true cargo_linux=true cargo_macos=%s cargo_lint=%s cargo_windows=%s cargo_windows_check=%s shards=%s' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$5" "$6" "$7"
}
# Outside every package.
PROSE_ROW="$(measured false false false false false false '[]')"
CODE_ROW="$(measured false false false false true false '[]')"
UI_ROW="$(measured false false false true true false '[]')"
# A build input runs `rest`, which builds kendex-cli for harness-ci's rows.
BUILD_ROW="$(measured true true false false true true '["rest"]')"
# tools/ and hooks/ run their suites' shard and the scans.
TOOL_ROW="$(measured true true false false true false '["guards-scans","guards-tools"]')"
# orch, and the skills declaring it, which `rest` runs.
ORCH_SHARDS="[$ORCH,\"guards-scans\",\"rest\"]"
ORCH_PROSE_ROW="$(measured true false false false false false "$ORCH_SHARDS")"
ORCH_CODE_ROW="$(measured true true false false true false "$ORCH_SHARDS")"

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
micro|false|skills/orch/SKILL.md .agents/skills/orch/SKILL.md|$ORCH_PROSE_ROW
small|false|crates/cli/src/main.rs|$BUILD_ROW
micro|false|ui/src/app.tsx|$UI_ROW
standard|false|skills/orch/scripts/lanes tools/guard|$(measured true true false false true false "[$ORCH,\"guards-scans\",\"guards-tools\",\"rest\"]")
standard|false|tools/ci-job-set.orig|$TOOL_ROW
micro|false|install.sh|$CODE_ROW
micro|false|.gitattributes|$CODE_ROW
micro|false|skills/orch/scripts/lanes|$ORCH_CODE_ROW
micro|false|tools/tests/ci-job-set.test.sh|$TOOL_ROW
micro|false|hooks/lane-mail-check|$TOOL_ROW
micro|false|skills/worktree/scripts/worktree|$(measured true true false false true false "[$ORCH,\"guards-scans\",\"worktree\"]")
micro|false|.agents/skills/worktree/scripts/worktree|$(measured true true false false true false "[$ORCH,\"worktree\"]")
micro|false|skills/review-gate/scripts/x|$(measured true true false false true false '["review-gate","guards-scans"]')
micro|false|skills/harness-ci/scripts/x|$(measured true true false false true false '["review-gate","guards-scans","rest"]')
micro|false|skills/commit-guards/scripts/x|$(measured true true false false true false '["guards-scans","guards-commit","guards-tools","rest"]')
micro|false|skills/preflight/scripts/x|$(measured true true false false true false '["guards-scans","linear"]')
micro|false|skills/deep-research/scripts/x.mjs|$(measured true true false false true false '["guards-scans","node"]')
micro|false|pi-extensions/pi-qol/src/x.ts|$(measured true true false false true false '["node"]')
micro|false|pi-extensions/pi-claude-bridge/src/x.ts|$(measured true true false false true false '["node","pi-claude-bridge"]')
micro|false|skills/AGENTS.md|$(measured true false false false false false '["guards-scans"]')
micro|false|.github/instructions/code-review.md|$(measured true false false false false false "$ROSTER")
micro|false|.github/AGENTS.md skills/orch/scripts/lanes|$(measured true true true false true false "$ROSTER")
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
[ "$selection_rows" -ge 38 ] ||
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
while IFS='|' read -r class path expected; do
  check "control: copies without the member $path run it as no lane source or build input" "$expected" \
    "$(SELECT_WITH="$TMP/member/tools/ci-job-set" selection "$class" false "$path")"
done <<ROWS
standard|tools/ci-aggregate|$TOOL_ROW
micro|.cargo|$CODE_ROW
ROWS

# A row that forgets a lane is refused before any lane reads it. macos_legs is
# the lane no aggregate holds, so this refusal is what keeps a forgotten
# platform lane from collapsing the matrix in silence. The copy drops one lane
# from the render row.
mkdir -p "$TMP/forgot/tools"
forgot="$TMP/forgot/tools/ci-job-set"
[ "$(grep -c "cargo_lint=false cargo_windows=false cargo_windows_check=false 'shards=\[\]'\$" "$JOB_SET")" -eq 1 ] ||
  { echo "the render row is no longer one line in $JOB_SET" >&2; exit 1; }
awk '
  /cargo_lint=false cargo_windows=false cargo_windows_check=false .shards=\[\].$/ {
    sub(/ cargo_windows_check=false/, "")
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
check "a file the Rust source reads at run time is no build input" "$TOOL_ROW" \
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
s/kind\[r\] != "manifest" .. //|micro|tools/x|$TOOL_ROW
s/if any "\$LANE_SOURCES"; then/if false; then/|standard|.github/workflows/skill-tests.yml|$ALL_ON
s/ci-aggregate.rust-reads)\$)/ci-aggregate.rust-reads))/|standard|tools/ci-job-set.orig|$TOOL_ROW
s/any '^ui\/' .. uitree=true/uitree=true/|micro|docs/a.md|$PROSE_ROW
CONTROLS

# The shard selection's rules, each removed from a copy run over this tree:
# the copy must answer its row other than the script does. Fields split on
# `@`, since the edits spell `|`. The second row is
# the inverse the selection must never reach, an orch diff selecting none of
# orch's shards.
while IFS='@' read -r edit class paths; do
  sed "$edit" "$JOB_SET" >"$TMP/rule/tools/ci-job-set"
  chmod +x "$TMP/rule/tools/ci-job-set"
  if cmp -s "$JOB_SET" "$TMP/rule/tools/ci-job-set"; then
    bad "control: the edit changed nothing in a ci-job-set copy: $edit"
    continue
  fi
  expected="$(selection "$class" false "$(printf '%s\n' $paths)")"
  got="$(SELECT_WITH="$TMP/rule/tools/ci-job-set" selection "$class" false "$(printf '%s\n' $paths)")"
  [ "$got" != "$expected" ] && ok "control: $edit reddens $class over $paths" ||
    bad "control: $edit reddens $class over $paths (still '$got')"
done <<'CONTROLS'
s/want_package "skills\/\$skill" ;; esac/;; esac/@micro@skills/worktree/scripts/worktree
s/skills\/\*\/\* | \.agents\/skills\/\*\/\*)/no-package)/@micro@skills/orch/scripts/lanes
s/skills\/\* | hooks\/\* | tools\/\*) want_shard guards-scans/no-tree) want_shard guards-scans/@micro@skills/AGENTS.md
s/\[ "\$1" = false \] || want_shard rest/:/@micro@crates/core/src/lib.rs
s/! any "\$ALL_SHARDS" || want_shard \$SHARDS/:/@micro@.github/instructions/code-review.md
s/! any "\$ALL_SHARDS" || macos_pr=\$macos/:/@micro@.github/AGENTS.md skills/orch/scripts/lanes
s/\[ "\$shards" != "\[\]" \] || shell=false/:/@micro@install.sh
s/\[ "\$shell:\$platform" != true:true \] || macos=true/macos=$platform/@micro@install.sh
CONTROLS

# A dependencies.required this reader cannot take as an inline list is
# refused, never read as no dependency.
DEP_WORLD="$TMP/dep-world"
mkdir -p "$DEP_WORLD/skills/block" "$DEP_WORLD/skills/plain"
cp -R "$READ_WORLD/crates" "$DEP_WORLD/crates"
printf -- '---\nname: block\ndependencies:\n  required:\n    - plain\n---\n' >"$DEP_WORLD/skills/block/SKILL.md"
printf -- '---\nname: plain\n---\n' >"$DEP_WORLD/skills/plain/SKILL.md"
check "a required list this reader cannot take is refused" \
  "exit=2 requirements-unreadable path=skills/block/SKILL.md" \
  "$(SELECT_IN="$DEP_WORLD" selection micro false skills/plain/scripts/x)"
printf -- '---\nname: block\ndependencies:\n  required: [plain]\n---\n' >"$DEP_WORLD/skills/block/SKILL.md"
check "and the inline list it can take selects the declaring skill's shard" \
  "$(measured true true false false true false '["guards-scans","rest"]')" \
  "$(SELECT_IN="$DEP_WORLD" selection micro false skills/plain/scripts/x)"

# --- 2. The names -----------------------------------------------------------
# Each reader is extracted with an anchored pattern: a name is the whole run
# of name characters after `needs.changes.outputs.`, so a misspelt name is a
# different member of the set, never a substring match of the right one.

OUTPUT_NAME='needs\.changes\.outputs\.[a-z_]+'

# A shard matrix key's expression, `os` or `shard`, the `${{ }}` stripped.
matrix_expr() { # WORKFLOW KEY
  sed -n "s/^        $2: \\\${{ \\(.*\\) }}\$/\\1/p" "$1"
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
    { matrix_expr "$1" os; matrix_expr "$1" shard; } | grep -oE "$OUTPUT_NAME" | sed 's/^needs\.changes\.outputs\.//' || true
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

legs() { # WORKFLOW SELECTION [RESULT] [EVENT] [KEY] — what a matrix key expands to, `os` by default
  local wf="$1" sel="$2" result="${3:-success}" event="${4:-pull_request}" map="$TMP/published-map" expr
  published_map "$wf" >"$map"
  expr="$(matrix_expr "$wf" "${5:-os}")"
  [ -n "$expr" ] || { printf 'no-matrix-expression'; return 0; }
  gh_eval value "$(context_json "$event" "$result" "$sel" "$map")" "$expr"
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
pull_request|$CODE_ROW|bot-instructions cargo-linux cargo-macos cargo-tests-windows markdown preflight
merge_group|$CODE_ROW|bot-instructions cargo-linux cargo-macos cargo-tests-windows
pull_request|$ORCH_CODE_ROW|bot-instructions cargo-linux cargo-macos cargo-tests-windows markdown preflight skill-suites-shard
merge_group|$ORCH_CODE_ROW|bot-instructions cargo-linux cargo-macos cargo-tests-windows skill-suites-shard
pull_request|$standard_code|bot-instructions cargo-check-windows cargo-lint cargo-linux cargo-macos cargo-tests-windows markdown preflight skill-suites-shard
merge_group|$standard_code|bot-instructions cargo-check-windows cargo-lint cargo-linux cargo-macos cargo-tests-windows skill-suites-shard
ROWS
[ "$job_rows" -ge 12 ] || { echo "the job table read $job_rows rows" >&2; exit 1; }

# The same property over every selection the table names: what a merge group
# runs is what its pull request ran less the event-held jobs.
without_event_held() { # JOBS — the jobs, spaced, with every event-held one dropped
  local job out=""
  for job in $1; do
    case " $EVENT_HELD " in *" $job "*) ;; *) out="$out $job" ;; esac
  done
  printf '%s' "${out# }"
}
for sel in "$VERIFY_ROW" "$ALL_ON" "$one_skill" "$CODE_ROW" "$ORCH_CODE_ROW" "$UI_ROW" "$PROSE_ROW" "$standard_code"; do
  check "a merge group runs its pull request's class job set under '$sel'" \
    "$(without_event_held "$(running "$WORKFLOW" "$sel" success pull_request)")" \
    "$(running "$WORKFLOW" "$sel" success merge_group)"
done

# A classifier that died published nothing. Every gated job runs, which is
# what each condition's status function and result term are for.
check "a dead classifier runs every gated job" "$EVERY_GATED" \
  "$(running "$WORKFLOW" "$ALL_OFF" failure)"

# EVENT|RESULT|SELECTION|LEGS. The macOS legs run in the merge group, and on
# the pull request only where the selection says a lane source changed.
leg_rows=0
while IFS='|' read -r event result sel expected; do
  leg_rows=$((leg_rows + 1))
  check "the matrix expands $expected on $event at $result under '$sel'" "$expected" \
    "$(legs "$WORKFLOW" "$sel" "$result" "$event")"
done <<ROWS
pull_request|success|$ALL_ON|["ubuntu-latest","macos-latest"]
merge_group|success|$ALL_ON|["ubuntu-latest","macos-latest"]
pull_request|success|$ORCH_CODE_ROW|["ubuntu-latest"]
merge_group|success|$ORCH_CODE_ROW|["ubuntu-latest","macos-latest"]
pull_request|success|$one_skill|["ubuntu-latest"]
merge_group|success|$one_skill|["ubuntu-latest"]
pull_request|failure|$ALL_OFF|["ubuntu-latest","macos-latest"]
merge_group|failure|$ALL_OFF|["ubuntu-latest","macos-latest"]
ROWS
[ "$leg_rows" -ge 8 ] || { echo "the leg table read $leg_rows rows" >&2; exit 1; }

# The shard key expands to the published list, and to the whole roster where
# nothing was published; that literal is the roster ci-job-set selects from,
# in its order, which the ALL_ON row's list is.
check "the shard matrix expands the selected shards" "[$ORCH,\"guards-scans\",\"rest\"]" \
  "$(legs "$WORKFLOW" "$ORCH_CODE_ROW" success merge_group shard)"
check "the shard matrix expands ci-job-set's roster, in order, when nothing classified" \
  "$(selection standard false .github/workflows/skill-tests.yml | sed 's/.*shards=//')" \
  "$(legs "$WORKFLOW" "$ALL_OFF" failure pull_request shard)"

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

# --- 3a'. Superseded runs ---------------------------------------------------
# A push to a pull request cancels the run its previous head started; a merge
# group or a push to main never shares a group with another run, so nothing
# cancels or queues it behind one. Each `${{ }}` of the workflow's
# concurrency values is evaluated and spliced back into its text.
concurrency_value() { # WORKFLOW KEY EVENT — the key's value on a run of that event
  local raw ctx out="" expr
  raw="$(awk -v key="$2" '
    /^concurrency:/ { on = 1; next }
    on && /^[^ ]/ { exit }
    on && $1 == key ":" { sub(/^ *[a-z-]+: */, ""); print }
  ' "$1")"
  [ -n "$raw" ] || { printf 'no-concurrency-%s' "$2"; return 0; }
  ctx="$(jq -cn --arg e "$3" '{github: {event_name: $e, run_id: 7}}
    | if $e == "pull_request" then .github.event = {pull_request: {number: 42}} else . end')"
  while [ -n "$raw" ]; do
    case "$raw" in
      *'${{'*)
        out="$out${raw%%'${{'*}"
        raw="${raw#*'${{'}"
        expr="${raw%%'}}'*}"
        raw="${raw#*'}}'}"
        out="$out$(gh_eval value "$ctx" "$expr" | tr -d '"')"
        ;;
      *) out="$out$raw"; raw="" ;;
    esac
  done
  printf '%s' "$out"
}
# EVENT|GROUP|CANCEL
concurrency_rows=0
while IFS='|' read -r event group cancel; do
  concurrency_rows=$((concurrency_rows + 1))
  check "a $event run's concurrency group and cancel" "$group $cancel" \
    "$(concurrency_value "$WORKFLOW" group "$event") $(concurrency_value "$WORKFLOW" cancel-in-progress "$event")"
done <<'ROWS'
pull_request|skill-tests-pull_request-42|true
merge_group|skill-tests-merge_group-7|false
push|skill-tests-push-7|false
ROWS
[ "$concurrency_rows" -ge 3 ] || { echo "the concurrency table read $concurrency_rows rows" >&2; exit 1; }
plant "$WORKFLOW" "cancel-in-progress: \${{ github.event_name == 'pull_request' }}" "cancel-in-progress: true" \
  "$TMP/wf-cancel-all.yml"
check "must-fail: a cancel held to no event cancels a merge group run" "true" \
  "$(concurrency_value "$TMP/wf-cancel-all.yml" cancel-in-progress merge_group)"

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

# The matrix without its event term runs the macOS legs on every pull request
# that selects them, which the merge group exists to take.
plant "$WORKFLOW" "(github.event_name != 'pull_request' || needs.changes.outputs.macos_pull_request == 'true')" \
  "true" "$TMP/wf-macos-pr.yml"
check "must-fail: a matrix ignoring the event runs macOS on the pull request" \
  '["ubuntu-latest","macos-latest"]' "$(legs "$TMP/wf-macos-pr.yml" "$ORCH_CODE_ROW")"

# The shard key reading no selection expands the whole roster on a diff that
# selected one package.
plant "$WORKFLOW" "|| needs.changes.outputs.shards)" "|| '$ROSTER')" "$TMP/wf-shards-unread.yml"
check "must-fail: a shard key reading no selection expands the whole roster" \
  "$ROSTER" "$(legs "$TMP/wf-shards-unread.yml" "$ORCH_CODE_ROW" success merge_group shard)"

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

# --- 4. The aggregate -------------------------------------------------------

RESULTS='{"changes":{"result":"success"},"skill-suites-shard":{"result":"success"},"ui-tests":{"result":"skipped"},"bot-instructions":{"result":"success"}}'
aggregate() { # AGGREGATE_SCRIPT LANE... — the exit status, and the refusal key when there is one
  local script="$1" status=0
  shift
  "$script" --results "$RESULTS" --classifier changes "$@" \
    >"$TMP/aggregate-out" 2>"$TMP/aggregate-err" || status=$?
  printf '%s' "$status"
  sed -n 's/^ci-aggregate: cause=/ /p' "$TMP/aggregate-err" | head -1
}

check "a lane the class stood down may skip" "0" \
  "$(aggregate "$AGGREGATE" --lane 'true:skill-suites-shard' --lane 'false:ui-tests' \
    --lane 'true:bot-instructions')"
check "a lane the class selected may not skip" "1" \
  "$(aggregate "$AGGREGATE" --lane 'true:skill-suites-shard' --lane 'true:ui-tests' \
    --lane 'true:bot-instructions')"
# One lane stood down turns the waiver on; the skipped lane beside it is one
# the class selected, so the waiver must not reach it.
check "a waiver for one lane authorizes no skip of another" "1" \
  "$(aggregate "$AGGREGATE" --lane 'true:skill-suites-shard' --lane 'true:ui-tests' \
    --lane 'false:bot-instructions')"
# The second selection for one job is refused before either becomes a waiver,
# whichever of the two comes last.
check "a job named twice is refused, the selected one first" \
  "2 duplicate-lane job=ui-tests" \
  "$(aggregate "$AGGREGATE" --lane 'true:ui-tests' --lane 'false:ui-tests')"
check "a job named twice is refused, the stood-down one first" \
  "2 duplicate-lane job=ui-tests" \
  "$(aggregate "$AGGREGATE" --lane 'false:ui-tests' --lane 'true:ui-tests')"

# A copy of the script parked where the harness-ci scripts are not, and one
# beside a scripts directory that holds no helper. Exit 1 is the helper's
# rejection of a lane, so neither may answer it.
mkdir -p "$TMP/no-dir/tools" "$TMP/no-helper/tools" "$TMP/no-helper/skills/harness-ci/scripts"
cp "$AGGREGATE" "$TMP/no-dir/tools/ci-aggregate"
cp "$AGGREGATE" "$TMP/no-helper/tools/ci-aggregate"
case "$(aggregate "$TMP/no-dir/tools/ci-aggregate" --lane 'false:ui-tests')" in
  "2 helper-unreadable dir="*) ok "a missing helper directory is a refusal, not a rejected lane" ;;
  *) bad "a missing helper directory is a refusal, not a rejected lane ($(cat "$TMP/aggregate-err"))" ;;
esac
case "$(aggregate "$TMP/no-helper/tools/ci-aggregate" --lane 'false:ui-tests')" in
  "2 helper-missing path="*) ok "a missing helper is a refusal, not a rejected lane" ;;
  *) bad "a missing helper is a refusal, not a rejected lane ($(cat "$TMP/aggregate-err"))" ;;
esac

# A classifier that died publishes no selection, so every lane reads empty.
# That authorizes nothing and the helper names the classifier.
DEAD='{"changes":{"result":"failure"},"ui-tests":{"result":"skipped"}}'
dead_status=0
"$AGGREGATE" --results "$DEAD" --classifier changes --lane ':ui-tests' \
  >/dev/null 2>"$TMP/dead-err" || dead_status=$?
check "a dead classifier authorizes no skip" "1" "$dead_status"
check "and the rejection names the classifier, not a parse failure" "1" \
  "$(grep -c 'aggregate-needs: rejected classifier=changes waiver=false' "$TMP/dead-err")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
