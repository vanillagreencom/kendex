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

# The cargo half of a row: the crates the Linux legs run, the macOS legs'
# crates, and whether a build input changed.
cargo_row() { # LINUX MACOS BUILD
  local macos=false
  [ -z "$2" ] || macos=true
  local linux=false
  [ -z "$1" ] || linux=true
  printf 'cargo_linux=%s cargo_macos=%s cargo_lint=%s cargo_windows=%s cargo_windows_check=%s linux_crates=%s macos_crates=%s' \
    "$linux" "$macos" "$3" "$macos" "$3" "$1" "$2"
}
EVERY="kendex-app,kendex-cli,kendex-core"
ALL_OFF="shell_shards=false macos_legs=false ui=false bot_instructions=false $(cargo_row '' '' false)"
ALL_ON="shell_shards=true macos_legs=true ui=true bot_instructions=true $(cargo_row "$EVERY" "$EVERY" true)"
# `render` and `trivial` run the one verify job.
VERIFY_ROW="shell_shards=false macos_legs=false ui=false bot_instructions=true $(cargo_row '' '' false)"
# The shell and verify lanes of a measured row: the macOS shell legs stand
# down on an all-prose diff, and ui off ui/.
PROSE_LANES="shell_shards=true macos_legs=false ui=false bot_instructions=true"
CODE_LANES="shell_shards=true macos_legs=true ui=false bot_instructions=true"
UI_LANES="shell_shards=true macos_legs=true ui=true bot_instructions=true"

# This repository's own tree: the class rows, and the rows the issue names.
# Every crate here has a `.` row, a read tools/rust-reads does not follow, so
# every crate runs on Linux for every measured diff; what a diff that builds
# nothing stands down is the lint and Windows compile lanes.
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
trivial|true|README.md|$PROSE_LANES $(cargo_row "$EVERY" '' false)
standard|false|crates/core/src/lib.rs|$CODE_LANES $(cargo_row "$EVERY" "$EVERY" true)
standard|false|tools/guard skills/orch/scripts/lanes|$CODE_LANES $(cargo_row "$EVERY" "$EVERY" false)
micro|false|skills/orch/SKILL.md .agents/skills/orch/SKILL.md|$PROSE_LANES $(cargo_row "$EVERY" '' false)
micro|false|Cargo.lock|$CODE_LANES $(cargo_row "$EVERY" "$EVERY" true)
standard|true|docs/guide.md CHANGELOG.md|$PROSE_LANES $(cargo_row "$EVERY" '' false)
enormous|false|skills/orch/SKILL.md|exit=2 unknown-class class=enormous
micro|false||exit=2 class-without-paths class=micro
micro|maybe|skills/orch/SKILL.md|exit=2 invalid-docs-only value=maybe
ROWS
[ "$selection_rows" -ge 12 ] ||
  { echo "the selection table read $selection_rows rows" >&2; exit 1; }

# A row that forgets a lane is refused before any lane reads it. macos_legs is
# the lane no aggregate holds, so this refusal is what keeps a forgotten
# platform lane from collapsing the matrix in silence. The copy drops one lane
# from the render row.
mkdir -p "$TMP/forgot/tools"
forgot="$TMP/forgot/tools/ci-job-set"
cp "$ROOT/tools/rust-reads" "$TMP/forgot/tools/rust-reads"
[ "$(grep -c 'cargo_windows=false cargo_windows_check=false \\$' "$JOB_SET")" -eq 1 ] ||
  { echo "the render row is no longer one line in $JOB_SET" >&2; exit 1; }
sed 's/cargo_windows=false cargo_windows_check=false \\$/cargo_windows_check=false \\/' "$JOB_SET" >"$forgot"
chmod +x "$forgot"
! cmp -s "$JOB_SET" "$forgot" || { echo "the forgotten-lane copy changed nothing" >&2; exit 1; }
forgot_status=0
CHANGE_CLASS=render DOCS_ONLY=false CHANGED_PATHS=CLAUDE.md GITHUB_OUTPUT="$TMP/forgot-out" \
  "$forgot" 2>"$TMP/forgot-err" || forgot_status=$?
check "a row that forgets a lane is refused" \
  "exit=2 lane-unselected lane=cargo_windows" \
  "exit=$forgot_status $(sed -n 's/^ci-job-set: cause=//p' "$TMP/forgot-err")"

# What a diff reaches, in a fixture checkout of three crates. kendex-core
# reads the checkout through a root helper it uses whole, the `.` row that
# may read anything; kendex-cli reads skills/ at run time and includes
# assets/x.json; kendex-app reads
# ui/src/bindings.ts at run time, includes docs/a.md, and reads docs/legal.
# What each source shape reads is tools/tests/rust-reads.test.sh's.
WORLD="$TMP/crate-world"
for c in core cli app; do
  mkdir -p "$WORLD/crates/$c/src"
  printf '[package]\nname = "kendex-%s"\n' "$c" >"$WORLD/crates/$c/Cargo.toml"
done
cat >"$WORLD/crates/core/src/lib.rs" <<'RS'
fn root() -> PathBuf { Path::new(env!("CARGO_MANIFEST_DIR")).join("../..") }
fn catalog() { open(&root()); }
RS
cat >"$WORLD/crates/cli/src/lib.rs" <<'RS'
fn skills() { scan(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../skills")); }
const X: &str = include_str!("../../../assets/x.json");
RS
cat >"$WORLD/crates/app/src/lib.rs" <<'RS'
const A: &str = include_str!("../../../docs/a.md");
const B: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../ui/src/bindings.ts");
fn legal() { read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docs/legal")); }
RS
CORE=kendex-core
CLI_CORE=kendex-cli,kendex-core
APP_CORE=kendex-app,kendex-core
ALL3=kendex-app,kendex-cli,kendex-core
# CLASS|DOCS_ONLY|PATHS (blank-separated)|EXPECTED
WORLD_ROWS="micro|false|tools/guard|$CODE_LANES $(cargo_row $CORE $CORE false)
standard|false|tools/guard skills/orch/scripts/lanes|$CODE_LANES $(cargo_row $CLI_CORE $CLI_CORE false)
micro|false|skills/orch/SKILL.md|$PROSE_LANES $(cargo_row $CLI_CORE '' false)
standard|false|skills/orch/SKILL.md|$CODE_LANES $(cargo_row $CLI_CORE '' false)
small|false|crates/app/src/lib.rs|$CODE_LANES $(cargo_row $ALL3 $ALL3 true)
micro|false|assets/x.json|$CODE_LANES $(cargo_row $ALL3 $ALL3 true)
micro|false|Cargo.lock|$CODE_LANES $(cargo_row $ALL3 $ALL3 true)
micro|false|.cargo/config.toml|$CODE_LANES $(cargo_row $ALL3 $ALL3 true)
micro|false|crates/AGENTS.md|$PROSE_LANES $(cargo_row $ALL3 '' false)
micro|false|ui/src/bindings.ts|$UI_LANES $(cargo_row $APP_CORE $APP_CORE false)
standard|false|ui/src/app.tsx|$UI_LANES $(cargo_row $CORE $CORE false)
micro|false|docs/a.md|$PROSE_LANES $(cargo_row $APP_CORE '' false)
trivial|true|docs/a.md|$PROSE_LANES $(cargo_row $APP_CORE '' false)
trivial|true|docs/legal/terms.md|$PROSE_LANES $(cargo_row $APP_CORE '' false)
trivial|true|docs/other.md docs/legal/privacy.md|$PROSE_LANES $(cargo_row $APP_CORE '' false)
trivial|true|docs/other.md|$VERIFY_ROW
trivial|true|docs/legalese.md|$VERIFY_ROW
render|true|docs/a.md|$VERIFY_ROW
standard|true|docs/guide.md|$PROSE_LANES $(cargo_row $CORE '' false)"
world_rows=0
while IFS='|' read -r class docs paths expected; do
  world_rows=$((world_rows + 1))
  check "reach: $class docs_only=$docs over '$paths'" "$expected" \
    "$(SELECT_IN="$WORLD" selection "$class" "$docs" "$(printf '%s\n' $paths)")"
done <<<"$WORLD_ROWS"
[ "$world_rows" -ge 19 ] || { echo "the reach table read $world_rows rows" >&2; exit 1; }
mkdir -p "$TMP/no-crates"
check "a read set rust-reads cannot derive is refused on a trivial diff" "exit=2 rust-reads-failed" \
  "$(SELECT_IN="$TMP/no-crates" selection trivial true docs/a.md)"
check "and on a measured one" "exit=2 rust-reads-failed" \
  "$(SELECT_IN="$TMP/no-crates" selection micro false tools/guard)"
# EDIT|CLASS|DOCS_ONLY|PATHS — a copy with that rule removed answers the row
# other than the table above does. An edit carries no |, the column
# separator.
mkdir -p "$TMP/rule/tools"
cp "$ROOT/tools/rust-reads" "$TMP/rule/tools/rust-reads"
controls=0
while IFS='|' read -r edit class docs paths; do
  controls=$((controls + 1))
  expected="$(printf '%s\n' "$WORLD_ROWS" | awk -F '|' -v c="$class" -v d="$docs" -v p="$paths" \
    '$1 == c && $2 == d && $3 == p { print $4; n++ } END { if (n != 1) exit 1 }')" ||
    { bad "control: no single reach row for $class $docs $paths"; continue; }
  sed "$edit" "$JOB_SET" >"$TMP/rule/tools/ci-job-set"
  chmod +x "$TMP/rule/tools/ci-job-set"
  if cmp -s "$JOB_SET" "$TMP/rule/tools/ci-job-set"; then
    bad "control: the edit changed nothing in a ci-job-set copy: $edit"
    continue
  fi
  got="$(SELECT_IN="$WORLD" SELECT_WITH="$TMP/rule/tools/ci-job-set" selection "$class" "$docs" "$(printf '%s\n' $paths)")"
  [ "$got" != "$expected" ] && ok "control: $edit reddens $class over $paths" ||
    bad "control: $edit reddens $class over $paths (still '$got')"
done <<'CONTROLS'
s/else if (c in dot) why = "."/else if (0) why = "."/|micro|false|tools/guard
s/if (input) why = "build"/if (0) why = "build"/|micro|false|assets/x.json
s/if (!prose) macos\[c\] = 1/macos[c] = 1/|micro|false|skills/orch/SKILL.md
s/if (!prose \&\& (kind/if ((kind/|micro|false|docs/a.md
s/if (crate\[r\] == c \&\& read/if (read/|micro|false|skills/orch/SKILL.md
/\[ "\$CHANGE_CLASS:\$DOCS_ONLY" != standard:false \] /d|standard|false|skills/orch/SKILL.md
s/any '^ui\/' \&\& uitree=true/uitree=true/|micro|false|tools/guard
s/row=trivial-read$/row=trivial/|trivial|true|docs/a.md
s/index(path, read "\/") == 1/index(path, read) == 1/|trivial|true|docs/legalese.md
CONTROLS
[ "$controls" -ge 9 ] || { echo "the control table read $controls rows" >&2; exit 1; }

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

# Each cargo leg's LEG_SELECTED expression, `JOB<tab>EXPR`, the `${{ }}`
# stripped. Only a line at the job env's own indent is read.
leg_exprs() { # WORKFLOW
  awk '
    /^jobs:/ { in_jobs = 1; next }
    !in_jobs { next }
    /^  [A-Za-z0-9_-]+:/ { job = $1; sub(/:$/, "", job); next }
    /^      LEG_SELECTED: \$\{\{ .* \}\}$/ {
      expr = $0
      sub(/^      LEG_SELECTED: \$\{\{ /, "", expr)
      sub(/ \}\}$/, "", expr)
      print job "\t" expr
    }
  ' "$1"
}

# Every lane a gate reads: the job conditions, the platform matrix and the
# cargo legs' LEG_SELECTED.
lanes_read() { # WORKFLOW
  { gate_pairs "$1" | sed 's/:.*//'
    matrix_expr "$1" | grep -oE "$OUTPUT_NAME" | sed 's/^needs\.changes\.outputs\.//' || true
    leg_exprs "$1" | grep -oE "$OUTPUT_NAME" | sed 's/^needs\.changes\.outputs\.//' || true
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


def text(v):
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)


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
        if name == "contains":
            if isinstance(args[0], str) and isinstance(args[1], str):
                return args[1].lower() in args[0].lower()
            refuse("cause=contains-operands")
        if name == "format":
            return re.sub(r"\{(\d+)\}", lambda m: text(args[1 + int(m.group(1))]), args[0])
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


def context(event, result, selection, map_file, crate=None):
    chosen = dict(pair.split("=", 1) for pair in selection.split())
    outputs = {}
    if result == "success":
        with open(map_file) as f:
            for line in f:
                name, source = line.split()
                if source in chosen:
                    outputs[name] = chosen[source]
    ctx = {"github": {"event_name": event},
           "needs": {"changes": {"result": result, "outputs": outputs}}}
    if crate is not None:
        ctx["matrix"] = {"crate": crate}
    return ctx


mode, event, result, selection, map_file = sys.argv[1:6]
ctx = context(event, result, selection, map_file, sys.argv[7] if mode == "leg" else None)
if mode in ("value", "leg"):
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
# The issue's two shapes on this tree: a diff of tools/ and skill scripts
# builds nothing, so the lint and Windows compile lanes stand down, and a
# crate source runs every cargo lane.
tools_only="$(selection standard false 'tools/guard
skills/orch/scripts/lanes')"
crate_code="$(selection small false crates/cli/src/main.rs)"
# SELECTION|EXPECTED JOBS
job_rows=0
while IFS='|' read -r sel expected; do
  job_rows=$((job_rows + 1))
  check "jobs under '$sel'" "$expected" "$(running "$WORKFLOW" "$sel")"
done <<ROWS
$VERIFY_ROW|bot-instructions
$ALL_ON|$EVERY_GATED
$one_skill|bot-instructions cargo-linux skill-suites-shard
$tools_only|bot-instructions cargo-linux cargo-macos cargo-tests-windows skill-suites-shard
$crate_code|bot-instructions cargo-check-windows cargo-lint cargo-linux cargo-macos cargo-tests-windows skill-suites-shard
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

# Each cargo leg's LEG_SELECTED, evaluated per crate: the crates the list
# names build and test, the others stand down, and a dead classifier or the
# push to main selects every leg. A name that only starts like a listed one
# is not listed.
leg() { # WORKFLOW JOB CRATE SELECTION [RESULT] [EVENT] — the leg's LEG_SELECTED
  local map="$TMP/published-map" expr
  published_map "$1" >"$map"
  expr="$(leg_exprs "$1" | awk -F '\t' -v j="$2" '$1 == j { print $2 }')"
  [ -n "$expr" ] || { printf 'no-leg-expression'; return 0; }
  python3 "$TMP/gh-eval.py" leg "${6:-pull_request}" "${5:-success}" "$4" "$map" "$expr" "$3"
}
check "the cargo legs are the jobs carrying LEG_SELECTED" "cargo-linux cargo-macos" \
  "$(leg_exprs "$WORKFLOW" | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
LEG_SEL="$(cargo_row kendex-cli,kendex-core-x kendex-cli true)"
# JOB|CRATE|RESULT|EVENT|EXPECTED
leg_rows=0
while IFS='|' read -r job crate result event expected; do
  leg_rows=$((leg_rows + 1))
  check "leg $job $crate under result=${result:-success} event=${event:-pull_request}" "$expected" \
    "$(leg "$WORKFLOW" "$job" "$crate" "$LEG_SEL" "$result" "$event")"
done <<'ROWS'
cargo-linux|kendex-cli|||true
cargo-linux|kendex-core|||false
cargo-linux|kendex-app|||false
cargo-macos|kendex-cli|||true
cargo-macos|kendex-core|||false
cargo-linux|kendex-app|failure||true
cargo-macos|kendex-app|failure||true
cargo-linux|kendex-app|skipped|push|true
ROWS
[ "$leg_rows" -ge 8 ] || { echo "the leg table read $leg_rows rows" >&2; exit 1; }

# Every step of a leg that builds or tests reads LEG_SELECTED, or a leg the
# diff does not reach pays for its crate anyway.
step_ifs() { # WORKFLOW JOB — `STEP<tab>IF` for the compile and test steps of JOB
  JOB="$2" awk '
    /^  [A-Za-z0-9_-]+:/ { job = $1; sub(/:$/, "", job); step = ""; next }
    job != ENVIRON["JOB"] { next }
    /^      - / { step = ""; if (match($0, /name: (compile|test)$/)) { step = $NF; cond[step] = "" } ; next }
    step != "" && /^        if: / { c = $0; sub(/^        if: /, "", c); cond[step] = c }
    END { for (s in cond) print s "\t" cond[s] }
  ' "$1" | LC_ALL=C sort
}
for job in cargo-linux cargo-macos; do
  ifs="$(step_ifs "$WORKFLOW" "$job")"
  [ "$(grep -c . <<<"$ifs")" -eq 2 ] ||
    { echo "the compile and test steps of $job were not read, so the extractor is broken" >&2; exit 1; }
  check "every build and test step of $job reads LEG_SELECTED" "" \
    "$(grep -vF "env.LEG_SELECTED == 'true'" <<<"$ifs" || true)"
done

# The document byte ceilings and the work-marker scan run in the job a
# `render` or `trivial` diff runs, and in no other, so every class that runs
# any gated job runs both scans. Each `run:` line is read with the job it
# sits in.
job_of_run() { # WORKFLOW COMMAND — the jobs whose `run:` line names it, sorted and spaced
  COMMAND="$2" awk '
    /^jobs:/ { in_jobs = 1; next }
    !in_jobs { next }
    /^  [A-Za-z0-9_-]+:/ { job = $1; sub(/:$/, "", job); next }
    /^ +run: / && index($0, ENVIRON["COMMAND"]) > 0 { print job }
  ' "$1" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'
}
VERIFY_JOBS="$(running "$WORKFLOW" "$VERIFY_ROW")"
[ -n "$VERIFY_JOBS" ] || { echo "the verify row runs no job, so the extractor is broken" >&2; exit 1; }
for scan in skills/doc-limits/scripts/doc-limits skills/commit-guards/scripts/todo-ban; do
  check "$scan runs in the verify job alone" "$VERIFY_JOBS" "$(job_of_run "$WORKFLOW" "$scan")"
done

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

# A LEG_SELECTED that reads no list selects a crate the diff did not reach.
plant "contains(format(',{0},', needs.changes.outputs.linux_crates), format(',{0},', matrix.crate))" \
  "true" "$TMP/wf-leg-unread.yml"
check "must-fail: a Linux leg that reads no crate list runs a crate the diff did not reach" \
  "true" "$(leg "$TMP/wf-leg-unread.yml" cargo-linux kendex-app "$LEG_SEL")"

# A compile step that forgot LEG_SELECTED builds a crate the diff did not
# reach.
awk '
  /^  [A-Za-z0-9_-]+:/ { job = $1; sub(/:$/, "", job) }
  job == "cargo-linux" && $0 == "      - name: compile" { seen = 1 }
  seen == 1 && $0 == "        if: env.LEG_SELECTED == '"'"'true'"'"'" { seen = 2; planted++; next }
  { print }
  END { if (planted != 1) exit 2 }
' "$WORKFLOW" >"$TMP/wf-compile-ungated.yml" ||
  { echo "the compile step condition could not be removed in a copy" >&2; exit 1; }
check "must-fail: a compile step that forgot LEG_SELECTED is reported" "compile	" \
  "$(step_ifs "$TMP/wf-compile-ungated.yml" cargo-linux | grep -vF "env.LEG_SELECTED == 'true'" || true)"

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
