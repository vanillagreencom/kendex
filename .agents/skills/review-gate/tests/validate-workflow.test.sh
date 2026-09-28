#!/usr/bin/env bash
# Workflow discovery and standalone command boundaries.
# Verdict records are the complete protocol consumed by validate.sh.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
. "$TEST_DIR/lib/sandbox.sh"
. "$TEST_DIR/lib/workflow-edit.sh"
DRIVER_REL="$WORKFLOW_REL"
WF='.github/workflows/review-gate-writer.yml'

# GitHub runs tracked direct children. Vary the candidate's location and
# engine-reference form while keeping the rest of the repository sound.
rows=0; before=$((PASS + FAIL))
while IFS='|' read -r shape check value note_check note_value; do
  [ -n "$shape" ] || continue
  rows=$((rows + 1))
  sandbox
  case "$shape" in
    sound) ;;
    missing) rm "$DIR/$WF"; commit "$DIR" ;;
    duplicate|non-ascii)
      copy='second-writer.yml'
      [ "$shape" != non-ascii ] || copy='rêview-writer.yml'
      cp "$DIR/$WF" "$DIR/.github/workflows/$copy"
      commit "$DIR" ;;
    bash-reference)
      printf '%s\n' 'name: Another writer' '"on":' '  workflow_dispatch: {}' 'jobs:' \
        '  write:' '    runs-on: ubuntu-latest' '    steps:' \
        '      - run: bash .agents/skills/review-gate/scripts/review-writer.sh' \
        >"$DIR/.github/workflows/other-writer.yml"
      commit "$DIR" ;;
    comment-reference)
      printf '%s\n' 'name: Mentions the writer in prose' '"on":' '  workflow_dispatch: {}' \
        'jobs:' '  talk:' '    runs-on: ubuntu-latest' '    steps:' \
        '      # review-writer.sh is named here and run nowhere' '      - run: echo hi' \
        >"$DIR/.github/workflows/mentions.yml"
      commit "$DIR" ;;
    symlink)
      (cd "$DIR/.github/workflows" && mv review-gate-writer.yml real-writer.yml && ln -s real-writer.yml review-gate-writer.yml)
      commit "$DIR" ;;
    nested-only|nested-copy)
      mkdir -p "$DIR/.github/workflows/archive"
      if [ "$shape" = nested-only ]; then
        mv "$DIR/$WF" "$DIR/.github/workflows/archive/review-gate-writer.yml"
      else
        cp "$DIR/$WF" "$DIR/.github/workflows/archive/old-writer.yml"
      fi
      commit "$DIR" ;;
    untracked-copy) cp "$DIR/$WF" "$DIR/.github/workflows/scratch.yml" ;;
    *) printf 'fixture-error=unknown-shape value=%q\n' "$shape" >&2; exit 2 ;;
  esac
  if [ "$check" = clean ]; then
    expect_clean "$shape" "$DIR" "$note_check" "$note_value"
  else
    expect_fail "$shape" "$DIR" "$check" "$value" "$note_check" "$note_value"
  fi
done <<'ROWS'
sound|clean|||
missing|workflow-count|0||
duplicate|workflow-count|2||
bash-reference|workflow-reference-count|2||
comment-reference|clean|||
symlink|workflow-symlink|.github/workflows/review-gate-writer.yml||
non-ascii|workflow-count|2||
nested-only|workflow-count|0|workflow-nested|.github/workflows/archive/review-gate-writer.yml
nested-copy|clean|||
untracked-copy|clean|||
ROWS
[ "$rows" -gt 0 ] && [ "$((PASS + FAIL - before))" -eq "$rows" ] || { printf 'fixture-error=discovery-table value=%q\n' "$rows" >&2; exit 2; }

# A writer may be absent only in a repository that posts no gate status, the
# writer setting counts only from the committed file, and an executed writer
# is checked in full whatever the setting says. An empty setting column leaves
# the key unassigned.
writer_setup() { # SOURCE WRITER MODE WRITER_SHAPE
  sandbox
  [ -z "$3" ] || settings "$DIR" REVIEW_GATE_MODE "$3"
  if [ -n "$2" ]; then
    case "$1" in
      committed) settings "$DIR" REVIEW_GATE_WRITER "$2" ;;
      local) mkdir -p "$DIR/.kendex"; printf '[env]\nREVIEW_GATE_WRITER = "%s"\n' "$2" >"$DIR/.kendex/settings.toml" ;;
      dotenv) printf 'REVIEW_GATE_WRITER=%s\n' "$2" >"$DIR/.env.local" ;;
      *) printf 'fixture-error=writer-source value=%q\n' "$1" >&2; exit 2 ;;
    esac
  fi
  case "$4" in
    absent) rm -- "${DIR:?}/$WF" ;;
    bash-reference)
      rm -- "${DIR:?}/$WF"
      printf '%s\n' 'name: Another writer' '"on":' '  workflow_dispatch: {}' 'jobs:' \
        '  write:' '    runs-on: ubuntu-latest' '    steps:' \
        '      - run: bash .agents/skills/review-gate/scripts/review-writer.sh' \
        >"$DIR/.github/workflows/other-writer.yml" ;;
    edited) file_edit "$DIR" "$WF" 1 '^    timeout-minutes: 15$' 's/^    timeout-minutes: 15$/    timeout-minutes: 16/' ;;
    *) printf 'fixture-error=writer-shape value=%q\n' "$4" >&2; exit 2 ;;
  esac
  commit "$DIR"
}
rows=0; before=$((PASS + FAIL))
while IFS='|' read -r name source writer mode shape want_rc record; do
  rows=$((rows + 1))
  writer_setup "$source" "$writer" "$mode" "$shape"
  run_validate "$DIR"
  if [ "$RC" -eq "$want_rc" ] && grep -qxF -- "$record" <<<"$OUT"; then ok "$name"; else bad "$name (rc=$RC, expected $record)" "$OUT"; fi
done <<'ROWS'
optional writer absent with the gate off|committed|optional|off|absent|0|ok check=workflow-absent value=optional
required writer absent with the gate off|committed|required|off|absent|1|FAIL check=workflow-count value=0
unassigned writer setting absent with the gate off|committed||off|absent|1|FAIL check=workflow-count value=0
machine-local optional writer is not read|local|optional|off|absent|1|FAIL check=workflow-count value=0
dotenv optional writer is not read|dotenv|optional|off|absent|1|FAIL check=workflow-count value=0
optional writer absent with the gate enforced|committed|optional|enforce|absent|1|FAIL check=workflow-absent-mode value=enforce
optional writer absent with the mode unassigned|committed|optional||absent|1|FAIL check=workflow-absent-mode value=enforce
a writer by another spelling is still a writer|committed|optional|off|bash-reference|1|FAIL check=workflow-reference-count value=1
optional writer present and edited|committed|optional|off|edited|1|FAIL check=workflow-equality value=.github/workflows/review-gate-writer.yml
invalid writer setting|committed|absent|off|absent|2|review-gate-error=writer-setting value=absent
invalid mode setting|committed|optional|of|absent|2|review-gate-error=mode-setting value=of
ROWS
[ "$rows" -gt 0 ] && [ "$((PASS + FAIL - before))" -eq "$rows" ] || { printf 'fixture-error=writer-table value=%q\n' "$rows" >&2; exit 2; }

# One control per rule, each on a sandbox copy: absence needs the optional
# setting, optional absence needs the gate off, the setting is read from
# neither machine-local file, and absence needs no other engine reference.
# Each mutant turns its rule's refusal into the pass.
SETTINGS_REL='.agents/skills/review-gate/scripts/lib/settings.sh'
rows=0; before=$((PASS + FAIL))
while IFS='~' read -r name source writer mode shape target matches pattern expression; do
  rows=$((rows + 1))
  writer_setup "$source" "$writer" "$mode" "$shape"
  file_edit "$DIR" "$target" "$matches" "$pattern" "$expression"
  chmod +x "$DIR/$target"
  run_validate "$DIR"
  if [ "$RC" -eq 0 ] && grep -qxF 'ok check=workflow-absent value=optional' <<<"$OUT"; then
    ok "control: $name"
  else bad "control: $name (rc=$RC)" "$OUT"; fi
done <<ROWS
a required writer passes as absent~committed~required~off~absent~$WORKFLOW_REL~1~^    none\)$~s/^    none)$/    none | required)/
an enforced gate passes an absent writer~committed~optional~enforce~absent~$SETTINGS_REL~1~^    enforce\) printf 'enforced' ;;$~s/printf 'enforced'/printf 'none'/
the machine-local file sets the writer~local~optional~off~absent~$SETTINGS_REL~1~= "REVIEW_GATE_WRITER" \]; then$~s/= "REVIEW_GATE_WRITER" ]/= "REVIEW_GATE_WRITER_UNREAD" ]/
the dotenv file sets the writer~dotenv~optional~off~absent~$SETTINGS_REL~2~^ *REVIEW_GATE_MODE \| REVIEW_GATE_WRITER\) ;;$~s/REVIEW_GATE_MODE | REVIEW_GATE_WRITER) ;;/REVIEW_GATE_MODE) ;;/
another spelling passes as absent~committed~optional~off~bash-reference~$WORKFLOW_REL~1~^      if \[ "\\\$engine_refs" -gt 0 \]; then$~s/-gt 0 ]; then$/-gt 0 ] \&\& false; then/
ROWS
[ "$rows" -gt 0 ] && [ "$((PASS + FAIL - before))" -eq "$rows" ] || { printf 'fixture-error=writer-control-table value=%q\n' "$rows" >&2; exit 2; }


rows=0; before=$((PASS + FAIL))
while IFS='|' read -r shape want_rc code; do
  rows=$((rows + 1))
  sandbox
  args=()
  value=''
  case "$shape" in
    help) args=(--help) ;;
    extra) args=(extra); value=1 ;;
    missing-template)
      value="$DIR/.agents/skills/review-gate/templates/review-gate-writer.yml"
      rm "$value" ;;
  esac
  RC=0
  OUT="$(cd "$DIR" && "./$WORKFLOW_REL" ${args[@]+"${args[@]}"} 2>&1)" || RC=$?
  expected=''
  [ -z "$code" ] || printf -v expected 'review-gate-error=%s value=%q' "$code" "$value"
  if [ "$RC" -eq "$want_rc" ] && { [ -z "$expected" ] || grep -qxF -- "$expected" <<<"$OUT"; }; then
    ok "$shape"
  else
    bad "$shape (rc=$RC, expected $expected)" "$OUT"
  fi
done <<'ROWS'
help|0|
extra|2|unknown-arguments
missing-template|2|template-missing
ROWS
[ "$rows" -gt 0 ] && [ "$((PASS + FAIL - before))" -eq "$rows" ] || { printf 'fixture-error=command-table value=%q\n' "$rows" >&2; exit 2; }

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
