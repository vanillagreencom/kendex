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
#      lane line, and the refusals beside them.
#   2. the names: the lanes the gates read, the lanes the changes job
#      publishes, the lanes ci-job-set selects, and the lane each aggregate
#      holds each job to are one set, compared by name.
#   3. the job set: each gated job's own `if:` and the platform matrix's
#      `os:` expression, read out of the workflow and EVALUATED against a
#      selection, with GitHub's implicit success() where a condition carries
#      no status function. A dead classifier runs every gated job and both
#      platform legs. Must-fail arms plant a lane condition that reads no
#      selection, one that drops its status function, and a matrix with its
#      arms swapped.
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

selection() { # CLASS DOCS_ONLY PATHS — the lane lines, blank-separated, or the refusal key
  local class="$1" docs="$2" paths="$3" out="$TMP/selection" status=0
  : >"$out"
  CHANGE_CLASS="$class" DOCS_ONLY="$docs" CHANGED_PATHS="$paths" \
    GITHUB_OUTPUT="$out" "$JOB_SET" 2>"$TMP/selection-err" || status=$?
  if [ "$status" -ne 0 ]; then
    printf 'exit=%s %s' "$status" \
      "$(sed -n 's/^ci-job-set: cause=//p' "$TMP/selection-err" | head -1)"
    return 0
  fi
  tr '\n' ' ' <"$out" | sed 's/ $//'
}

ALL_OFF="shell_shards=false macos_legs=false ui=false bot_instructions=false cargo_linux=false cargo_macos=false cargo_lint=false cargo_windows=false"
ALL_ON="shell_shards=true macos_legs=true ui=true bot_instructions=true cargo_linux=true cargo_macos=true cargo_lint=true cargo_windows=true"
# Every measured class runs the three Linux lanes, which hold every content
# reader; the platform, lint and ui lanes follow the paths.
PROSE_ROW="shell_shards=true macos_legs=false ui=false bot_instructions=true cargo_linux=true cargo_macos=false cargo_lint=false cargo_windows=false"
WORKSPACE_ROW="shell_shards=true macos_legs=true ui=false bot_instructions=true cargo_linux=true cargo_macos=true cargo_lint=true cargo_windows=true"
UI_ROW="shell_shards=true macos_legs=true ui=true bot_instructions=true cargo_linux=true cargo_macos=false cargo_lint=false cargo_windows=false"

# CLASS|DOCS_ONLY|PATHS (blank-separated)|EXPECTED
selection_rows=0
while IFS='|' read -r class docs paths expected; do
  selection_rows=$((selection_rows + 1))
  check "selection: $class docs_only=$docs over '$paths'" "$expected" \
    "$(selection "$class" "$docs" "$(printf '%s\n' $paths)")"
done <<ROWS
render|false|.agents/skills/orch/SKILL.md .claude/skills/orch/SKILL.md|$ALL_OFF
trivial|true|docs/architecture/overview.md|$ALL_OFF
standard|false|crates/core/src/lib.rs|$ALL_ON
micro|false|skills/orch/SKILL.md .agents/skills/orch/SKILL.md|$PROSE_ROW
small|false|crates/cli/src/main.rs|$WORKSPACE_ROW
micro|false|ui/src/app.tsx|$UI_ROW
micro|false|clippy.toml|$WORKSPACE_ROW
micro|false|rust-toolchain.toml|$WORKSPACE_ROW
micro|true|docs/guide.md CHANGELOG.md|$PROSE_ROW
small|true|docs/guide.md CHANGELOG.md|$PROSE_ROW
standard|true|docs/guide.md CHANGELOG.md|$PROSE_ROW
standard|false|docs/guide.md|$ALL_ON
enormous|false|skills/orch/SKILL.md|exit=2 unknown-class class=enormous
micro|false||exit=2 class-without-paths class=micro
micro|maybe|skills/orch/SKILL.md|exit=2 invalid-docs-only value=maybe
ROWS
[ "$selection_rows" -ge 15 ] ||
  { echo "the selection table read $selection_rows rows" >&2; exit 1; }

# The docs verdict narrows a `standard` diff to the row its paths select as a
# measured class, and to nothing narrower.
docs_paths="$(printf '%s\n' docs/architecture/overview.md docs/legal/terms.md)"
check "standard with docs_only=true takes the small row for the same paths" \
  "$(selection small false "$docs_paths")" "$(selection standard true "$docs_paths")"

# A row that forgets a lane is refused before any lane reads it. macos_legs is
# the lane no aggregate holds, so this refusal is what keeps a forgotten
# platform lane from collapsing the matrix in silence. The copy drops one lane
# from the render row.
mkdir -p "$TMP/forgot/tools"
forgot="$TMP/forgot/tools/ci-job-set"
[ "$(grep -c 'cargo_linux=false cargo_macos=false cargo_lint=false cargo_windows=false$' "$JOB_SET")" -eq 1 ] ||
  { echo "the render row is no longer one line in $JOB_SET" >&2; exit 1; }
awk '
  /cargo_linux=false cargo_macos=false cargo_lint=false cargo_windows=false$/ {
    sub(/ cargo_windows=false$/, "")
  }
  { print }
' "$JOB_SET" >"$forgot"
chmod +x "$forgot"
! cmp -s "$JOB_SET" "$forgot" || { echo "the forgotten-lane copy changed nothing" >&2; exit 1; }
forgot_status=0
CHANGE_CLASS=render DOCS_ONLY=false CHANGED_PATHS=CLAUDE.md GITHUB_OUTPUT="$TMP/forgot-out" \
  "$forgot" 2>"$TMP/forgot-err" || forgot_status=$?
check "a row that forgets a lane is refused" \
  "exit=2 lane-unselected lane=cargo_windows" \
  "exit=$forgot_status $(sed -n 's/^ci-job-set: cause=//p' "$TMP/forgot-err")"

# --- 2. The names -----------------------------------------------------------
# Each reader is extracted with an anchored pattern: a name is the whole run
# of name characters after `needs.changes.outputs.`, so a misspelt name is a
# different member of the set, never a substring match of the right one.

OUTPUT_NAME='needs\.changes\.outputs\.[a-z_]+'

# One `JOB<tab>EXPR` line per job with a job-level `if:`, the `${{ }}`
# stripped. Only a line at the job's own indent is read.
job_ifs() { # WORKFLOW
  awk '
    /^jobs:/ { in_jobs = 1; next }
    !in_jobs { next }
    /^  [A-Za-z0-9_-]+:/ { job = $1; sub(/:$/, "", job); next }
    /^    if:/ {
      expr = $0
      sub(/^    if:[ ]*/, "", expr)
      if (substr(expr, 1, 3) == "${{") { expr = substr(expr, 4); sub(/}}[ ]*$/, "", expr) }
      print job "\t" expr
    }
  ' "$1"
}

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

# `LANE:JOB` for every `--lane "$VAR:JOB"` an aggregate passes, VAR resolved
# through that same job's `VAR: ${{ needs.changes.outputs.LANE }}` entry. An
# unresolved VAR prints as `?`, which matches no lane.
aggregate_pairs() { # WORKFLOW
  awk '
    /^  [A-Za-z0-9_-]+:/ { split("", var) }
    match($0, /^          [A-Z_]+: \$\{\{ needs\.changes\.outputs\.[a-z_]+ \}\}$/) {
      name = $1; sub(/:$/, "", name)
      lane = $0; sub(/.*needs\.changes\.outputs\./, "", lane); sub(/ .*/, "", lane)
      var[name] = lane
    }
    match($0, /--lane "\$[A-Z_]+:[a-z0-9-]+"/) {
      pair = substr($0, RSTART + 9, RLENGTH - 10)
      name = pair; sub(/:.*/, "", name)
      job = pair; sub(/^[^:]*:/, "", job)
      print ((name in var) ? var[name] : "?") ":" job
    }
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
check "the aggregates hold each gated job to the lane its own condition reads" \
  "$GATE_PAIRS" "$(aggregate_pairs "$WORKFLOW")"

# --- 3. The job set ---------------------------------------------------------
# The evaluator covers the expression forms these conditions use: string,
# number and boolean literals, context paths, `!`, `==`, `!=`, `&&`, `||`,
# parentheses, and the functions fromJSON, always, cancelled and success.
# Anything else is a refusal, not a guess. `==` compares strings without
# regard to case, `&&` and `||` return an operand, and a path that names no
# value is null, as GitHub evaluates them.
cat >"$TMP/gh-eval.py" <<'PY'
import json, re, sys

TOKEN = re.compile(r"\s*(?:(\|\||&&|==|!=|!|\(|\)|,)|'((?:[^']|'')*)'"
                   r"|([A-Za-z_][A-Za-z0-9_-]*(?:\.[A-Za-z_][A-Za-z0-9_-]*)*)|(\d+))")
STATUS = ("always", "cancelled", "success", "failure")


def refuse(msg):
    sys.stderr.write("gh-eval: " + msg + "\n")
    sys.exit(2)


def tokens(src):
    out, i, src = [], 0, src.strip()
    while i < len(src):
        m = TOKEN.match(src, i)
        if not m or m.end() == i:
            refuse("cause=untokenizable at=%d expr=%s" % (i, src))
        op, string, ident, num = m.groups()
        if op:
            out.append(("op", op))
        elif string is not None:
            out.append(("str", string.replace("''", "'")))
        elif ident:
            out.append(("id", ident))
        else:
            out.append(("num", int(num)))
        i = m.end()
    return out


def truthy(v):
    return not (v is None or v is False or v == "" or (type(v) in (int, float) and v == 0))


def equal(a, b):
    if isinstance(a, str) and isinstance(b, str):
        return a.lower() == b.lower()
    return a == b


class Parser:
    def __init__(self, toks, ctx):
        self.t, self.i, self.ctx = toks, 0, ctx

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else (None, None)

    def expect(self, value):
        if self.peek() != ("op", value):
            refuse("cause=expected token=%s at=%d" % (value, self.i))
        self.i += 1

    def whole(self):
        v = self.or_()
        if self.i != len(self.t):
            refuse("cause=trailing-tokens at=%d" % self.i)
        return v

    def or_(self):
        v = self.and_()
        while self.peek() == ("op", "||"):
            self.i += 1
            r = self.and_()
            v = v if truthy(v) else r
        return v

    def and_(self):
        v = self.cmp()
        while self.peek() == ("op", "&&"):
            self.i += 1
            r = self.cmp()
            v = r if truthy(v) else v
        return v

    def cmp(self):
        v = self.unary()
        kind, op = self.peek()
        if kind == "op" and op in ("==", "!="):
            self.i += 1
            r = self.unary()
            v = equal(v, r) if op == "==" else not equal(v, r)
        return v

    def unary(self):
        if self.peek() == ("op", "!"):
            self.i += 1
            return not truthy(self.unary())
        return self.primary()

    def primary(self):
        kind, v = self.peek()
        if (kind, v) == ("op", "("):
            self.i += 1
            r = self.or_()
            self.expect(")")
            return r
        if kind in ("str", "num"):
            self.i += 1
            return v
        if kind != "id":
            refuse("cause=unexpected-token at=%d" % self.i)
        self.i += 1
        if v in ("true", "false"):
            return v == "true"
        if v == "null":
            return None
        if self.peek() == ("op", "("):
            self.i += 1
            args = []
            if self.peek() != ("op", ")"):
                args.append(self.or_())
                while self.peek() == ("op", ","):
                    self.i += 1
                    args.append(self.or_())
            self.expect(")")
            return self.call(v, args)
        return self.lookup(v)

    def call(self, name, args):
        if name == "fromJSON":
            return json.loads(args[0])
        if name == "always":
            return True
        if name == "cancelled":
            return False
        if name == "success":
            return self.ctx["needs"]["changes"]["result"] == "success"
        refuse("cause=unknown-function name=%s" % name)

    def lookup(self, path):
        parts = path.split(".")
        if parts[0] not in self.ctx:
            refuse("cause=unknown-context name=%s" % parts[0])
        v = self.ctx
        for p in parts:
            v = v.get(p) if isinstance(v, dict) else None
        return v


def context(event, result, selection, map_file):
    chosen = dict(pair.split("=", 1) for pair in selection.split())
    outputs = {}
    if result == "success":
        with open(map_file) as f:
            for line in f:
                name, source = line.split()
                if source in chosen:
                    outputs[name] = chosen[source]
    return {"github": {"event_name": event},
            "needs": {"changes": {"result": result, "outputs": outputs}}}


mode, event, result, selection, map_file = sys.argv[1:6]
ctx = context(event, result, selection, map_file)
if mode == "value":
    print(json.dumps(Parser(tokens(sys.argv[6]), ctx).whole(), separators=(",", ":")))
elif mode == "jobs":
    for line in sys.stdin:
        job, expr = line.rstrip("\n").split("\t", 1)
        # A condition naming no status function runs under GitHub's implicit
        # success(), which a dead classifier makes false.
        if not any(re.search(r"\b%s\(" % f, expr) for f in STATUS):
            expr = "success() && (%s)" % expr
        if truthy(Parser(tokens(expr), ctx).whole()):
            print(job)
else:
    refuse("cause=unknown-mode mode=%s" % mode)
PY

# The jobs a class stands down or runs: every job whose own condition reads
# a lane, and every job an aggregate holds, since a job an aggregate holds
# whose condition reads nothing runs on every class.
gated_jobs() { # WORKFLOW
  { gate_pairs "$1"; aggregate_pairs "$1"; } | sed 's/^[^:]*://' | LC_ALL=C sort -u
}

running() { # WORKFLOW SELECTION [RESULT] — the gated jobs that run, sorted and spaced
  local wf="$1" sel="$2" result="${3:-success}" map="$TMP/published-map" job
  published_map "$wf" >"$map"
  gated_jobs "$wf" >"$TMP/gated"
  job_ifs "$wf" | while IFS="$(printf '\t')" read -r job expr; do
    grep -qxF -- "$job" "$TMP/gated" && printf '%s\t%s\n' "$job" "$expr"
  done >"$TMP/gated-ifs" || true
  python3 "$TMP/gh-eval.py" jobs pull_request "$result" "$sel" "$map" <"$TMP/gated-ifs" |
    LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'
}

legs() { # WORKFLOW SELECTION [RESULT] — the platform legs the matrix expands to
  local wf="$1" sel="$2" result="${3:-success}" map="$TMP/published-map" expr
  published_map "$wf" >"$map"
  expr="$(matrix_expr "$wf")"
  [ -n "$expr" ] || { printf 'no-matrix-expression'; return 0; }
  python3 "$TMP/gh-eval.py" value pull_request "$result" "$sel" "$map" "$expr"
}

EVERY_GATED="bot-instructions cargo-check-windows cargo-lint cargo-linux cargo-macos cargo-tests-windows skill-suites-shard ui-tests"
check "the gated set is read out of the workflow" "$EVERY_GATED" \
  "$(gated_jobs "$WORKFLOW" | tr '\n' ' ' | sed 's/ $//')"

one_skill="$(selection micro false 'skills/orch/SKILL.md
.agents/skills/orch/SKILL.md')"
# SELECTION|EXPECTED JOBS
job_rows=0
while IFS='|' read -r sel expected; do
  job_rows=$((job_rows + 1))
  check "jobs under '$sel'" "$expected" "$(running "$WORKFLOW" "$sel")"
done <<ROWS
$ALL_OFF|
$ALL_ON|$EVERY_GATED
$one_skill|bot-instructions cargo-linux skill-suites-shard
$WORKSPACE_ROW|bot-instructions cargo-check-windows cargo-lint cargo-linux cargo-macos cargo-tests-windows skill-suites-shard
$UI_ROW|bot-instructions cargo-linux skill-suites-shard ui-tests
ROWS
[ "$job_rows" -ge 5 ] || { echo "the job table read $job_rows rows" >&2; exit 1; }

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

# --- 3b. Must-fail controls -------------------------------------------------
plant() { # FROM TO OUT — replace FROM once in the workflow, or stop
  local from="$1" to="$2" out="$3"
  [ "$(grep -cF -- "$from" "$WORKFLOW")" -eq 1 ] ||
    { echo "the planted text is no longer one line: $from" >&2; exit 1; }
  FROM="$from" TO="$to" awk '
    { i = index($0, ENVIRON["FROM"]) }
    i > 0 { $0 = substr($0, 1, i - 1) ENVIRON["TO"] substr($0, i + length(ENVIRON["FROM"])) }
    { print }
  ' "$WORKFLOW" >"$out"
  ! cmp -s "$WORKFLOW" "$out" ||
    { echo "the planted edit changed nothing: $from" >&2; exit 1; }
}

# The pre-patch shape of the macOS cargo lane: gated on the event alone. It
# runs on the one-skill row, which is the full battery the narrowing exists
# to avoid.
plant "!cancelled() && (github.event_name == 'push' || needs.changes.result != 'success' || needs.changes.outputs.cargo_macos == 'true')" \
  "!cancelled()" "$TMP/wf-ungated.yml"
case " $(running "$TMP/wf-ungated.yml" "$one_skill") " in
  *" cargo-macos "*) ok "must-fail: a lane condition reading no selection runs on the one-skill row" ;;
  *) bad "must-fail: an ungated macOS cargo lane still reads as gated" ;;
esac

# A condition without its status function keeps GitHub's implicit success()
# and stands its lane down on exactly the run nothing classified.
plant "!cancelled() && github.event_name != 'push' && (needs.changes.result != 'success' || needs.changes.outputs.ui == 'true')" \
  "github.event_name != 'push' && (needs.changes.result != 'success' || needs.changes.outputs.ui == 'true')" \
  "$TMP/wf-no-status.yml"
case " $(running "$TMP/wf-no-status.yml" "$ALL_OFF" failure) " in
  *" ui-tests "*) bad "must-fail: a condition with no status function still runs under a dead classifier" ;;
  *) ok "must-fail: a condition with no status function stands down under a dead classifier" ;;
esac

# The matrix with its two arms swapped runs macOS exactly where the class
# dropped it.
plant "'[\"ubuntu-latest\", \"macos-latest\"]' || '[\"ubuntu-latest\"]'" \
  "'[\"ubuntu-latest\"]' || '[\"ubuntu-latest\", \"macos-latest\"]'" "$TMP/wf-swapped.yml"
check "must-fail: a matrix with its arms swapped expands the wrong legs" \
  '["ubuntu-latest","macos-latest"]' "$(legs "$TMP/wf-swapped.yml" "$one_skill")"

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
