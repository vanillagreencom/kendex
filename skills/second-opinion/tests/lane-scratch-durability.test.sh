#!/usr/bin/env bash
# Regression test for multi-lane scratch durability and lane-artifact handling
# (VST-221).
#
# The multi-lane parent kept two things in one `mktemp -d` scratch directory:
# each lane's captured stderr, and a `wrap-<lane>.json` re-wrap of the lane's
# review that the union merge read back at the end. Anything that removed that
# directory mid-run — the reviewed repo's own agent CLI, a sandbox, a tmp
# reaper — made the parent report BOTH healthy lanes as unusable and exit 4
# with no external verdict, even though both lane artifacts sat intact and
# valid beside the union path. Without --output the lane artifacts lived in
# that same directory, so clearing it dropped a lane's real findings and the
# union still published a pass.
#
# Contract pinned here:
#   * The parent creates exactly one directory under TMPDIR and everything in
#     it is disposable — losing it costs the stderr replay and nothing else, in
#     BOTH --output and stdout mode. Each lane's review is held in memory from
#     the moment that lane is reaped.
#   * That replay actually reaches the operator: a healthy lane's log and a
#     failing lane's own cause text both arrive on the parent's stderr, lane-
#     prefixed. This is the only channel by which an operator diagnoses exit 5.
#   * An artifact is usable only if it holds exactly one JSON object shaped the
#     way the union merge consumes it. No JSON value at all (jq exits 0 and
#     prints nothing), a truncated stream, or a finding that is not an object
#     are all that lane answering unusably — never a healthy lane contributing
#     nothing, and never an aborted merge that drops the other lane's review.
#   * A lane that exits 0 without a usable artifact is reported with a truthful
#     lane-failure code, never a bare "exit 0" — and that class must not flip
#     the all-lanes-failed aggregate from 5 (nobody answered) to 4 (somebody
#     answered unusably).
#   * Temp space is left clean and owner-only: lane children run under a
#     restrictive umask, and the parent removes every artifact and sidecar it
#     caused to be written there — without letting that cleanup change the
#     run's exit status.
#
# Drives a hermetic copy of the skill (vstack#580) with fake lane CLIs.

set -euo pipefail

# Declare this session as having no model (none), so the cross-model
# guard neither depends on nor is defeated by the harness running the tests.
export SECOND_OPINION_CURRENT_MODEL=none

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
# A scenario below deliberately leaves a directory the run cannot write into,
# so make the tree removable before removing it. Both commands are guarded for
# the same reason the production trap guards its own: a trap runs under set -e,
# so a failure here would skip the rest of the cleanup and override the exit
# status of a suite whose assertions all passed.
trap 'chmod -R u+rwX "$TMP_ROOT" 2>/dev/null || true; rm -rf "$TMP_ROOT" || true' EXIT

# --- Deterministic harness-free session -------------------------------------
# A positively detected single-model harness now beats any contradicting
# declaration, whatever its source — so a suite can no longer neutralize the
# harness that runs it by exporting an identity. It has to actually not have
# one. This `ps` stand-in reports the first parent as init, so the ancestor walk
# finds nothing and the declared identity below is what the script uses. It also
# makes these suites independent of where they run: same result under Claude
# Code, under Codex, and in CI.
_PSBIN="$TMP_ROOT/psbin"
mkdir -p "$_PSBIN"
cat > "$_PSBIN/ps" <<'PSSH'
#!/usr/bin/env bash
mode=""; while [[ $# -gt 0 ]]; do case "$1" in -o) mode="$2"; shift 2 ;; *) shift ;; esac; done
case "$mode" in ppid=) printf '1\n' ;; comm=) printf 'bash\n' ;; esac
PSSH
chmod +x "$_PSBIN/ps"
PATH="$_PSBIN:$PATH"
export PATH
# The process tree is only half the signal; the environment markers are the
# other half, and this session's are inherited. Drop them too.
unset CLAUDECODE CLAUDE_CODE CLAUDE_PROJECT_DIR CODEX_SANDBOX \
      CODEX_SANDBOX_NETWORK_DISABLED PI_CODING_AGENT_DIR OPENCODE \
      CURSOR_AGENT CURSOR_TRACE_ID

mkdir -p "$TMP_ROOT/proj/skills"
git init -q "$TMP_ROOT/proj"
cp -R "$REPO_ROOT/skills/second-opinion" "$TMP_ROOT/proj/skills/second-opinion"
SECOND_OPINION="$TMP_ROOT/proj/skills/second-opinion/scripts/second-opinion"

PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }
# For a check this runner cannot construct — never for one it merely did not
# run. Counted separately so the summary line stays honest about coverage that
# was not obtained.
skip() { SKIP=$((SKIP + 1)); printf '  skip  %s\n' "$1"; }

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    pass "$name"
  else
    fail "$name"
    printf '        expected: %s\n        got:      %s\n' "$want" "$got" >&2
  fi
}

assert_file_exists() {
  local file="$1" name="$2"
  if [[ -f "$file" ]]; then
    pass "$name"
  else
    fail "$name"
    printf '        expected file to exist: %s\n' "$file" >&2
  fi
}

assert_file_absent() {
  local file="$1" name="$2"
  if [[ -e "$file" ]]; then
    fail "$name"
    printf '        expected file NOT to exist: %s\n' "$file" >&2
  else
    pass "$name"
  fi
}

assert_jq() {
  local file="$1" expr="$2" want="$3" name="$4" got
  got="$(jq -r "$expr" "$file" 2>/dev/null || echo "JQ_ERROR")"
  assert_eq "$got" "$want" "$name"
}

assert_stderr_has() {
  local needle="$1" name="$2"
  if grep -qF "$needle" "$TMP_ROOT/last.stderr"; then
    pass "$name"
  else
    fail "$name"
    printf '        expected stderr to contain: %s\n' "$needle" >&2
  fi
}

assert_stderr_lacks() {
  local needle="$1" name="$2"
  if grep -qF "$needle" "$TMP_ROOT/last.stderr"; then
    fail "$name"
    printf '        expected stderr NOT to contain: %s\n' "$needle" >&2
  else
    pass "$name"
  fi
}

# Nothing the run caused to be written may survive in temp space or in the
# artifact home — not the lane artifact, not the sidecar family a lane child
# writes beside it. The parent's promise is "leaves nothing behind", so the
# predicate is any regular file at all; the jq probe only enriches the failure
# message. The home's own `*` ignore file is the tool's marker for the
# directory, not something a run wrote, and is excluded by name.
assert_no_leftovers() {
  local name="$1" leftover detail=""
  leftover="$(find "$SCRATCH" "$ARTIFACT_HOME_DIR" -type f ! -name .gitignore 2>/dev/null | head -1 || true)"
  if [[ -n "$leftover" ]]; then
    if jq -e '.agent // "" | startswith("external-")' "$leftover" >/dev/null 2>&1; then
      detail=" (a lane review)"
    fi
    fail "$name"
    printf '        left behind%s: %s\n' "$detail" "$leftover" >&2
  else
    pass "$name"
  fi
}

# The model's raw review text about the reviewed repository must never be
# world- or group-readable while it sits in shared temp space.
assert_owner_only() {
  local file="$1" name="$2" loose
  loose="$(find "$file" -type f \( -perm -g+r -o -perm -o+r \) 2>/dev/null || true)"
  if [[ -n "$loose" ]]; then
    fail "$name"
    printf '        readable beyond the owner: %s\n' "$(ls -l "$file" 2>/dev/null)" >&2
  else
    pass "$name"
  fi
}

# The paired direction, and the control for every owner-only assertion: a file
# this tool did not write must come out at the CALLER's umask, or a restriction
# leaking past its own artifacts reads as "merely more restrictive". Read bits
# only; `find -perm` over `stat`, whose flags differ GNU/BSD.
assert_group_other_readable() {
  local path="$1" name="$2"
  if [[ -n "$(find "$path" -maxdepth 0 -perm -g+r -perm -o+r 2>/dev/null)" ]]; then
    pass "$name"
  else
    fail "$name"
    printf '        expected group- and other-readable: %s\n' "$(ls -ld "$path" 2>/dev/null)" >&2
  fi
}

assert_probe_empty() {
  local probe="$1" name="$2"
  if [[ -s "$probe" ]]; then
    fail "$name"
    printf '        probe recorded: %s\n' "$(cat "$probe")" >&2
  else
    pass "$name"
  fi
}

# An empty "loose files" recording only means something if the probe actually
# looked at files. Without this, a renamed sidecar makes the permission check
# vacuous and still green.
assert_probe_saw_files() {
  local probe="$1" name="$2" count=0
  [[ -s "$probe" ]] && count="$(tr -d ' \n' < "$probe")"
  if [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -gt 0 ]]; then
    pass "$name"
  else
    fail "$name"
    printf '        probe saw %s files in temp space\n' "${count:-0}" >&2
  fi
}

# --- Reviewed repo ------------------------------------------------------------
WORK="$TMP_ROOT/work"
mkdir -p "$WORK"
git -C "$WORK" init -q
git -C "$WORK" config user.email test@example.com
git -C "$WORK" config user.name test
printf 'hello\n' > "$WORK/file.txt"
git -C "$WORK" add file.txt
git -C "$WORK" -c commit.gpgsign=false commit -q -m init
printf 'world\n' >> "$WORK/file.txt"

# --- Scratch sandbox ----------------------------------------------------------
# TMPDIR is pointed at a directory this test owns, so the reaper stub below can
# clear the parent's scratch directory instead of touching the ambient /tmp,
# and so leftovers can be attributed to the run under test.
SCRATCH="$TMP_ROOT/scratch"
mkdir -p "$SCRATCH"
PERM_PROBE="$TMP_ROOT/perm-probe"
# Lane reviews and the sidecars beside them live in the home the tool owns
# inside the reviewed project, not in shared temp space, so every check about
# what a run leaves behind or exposes has two roots to look at.
ARTIFACT_HOME_DIR="$WORK/tmp/second-opinion"

mkdir -p "$TMP_ROOT/bin"

# Lane stub that answers with the response file named by $1.
cat > "$TMP_ROOT/bin/lane-answer" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
cat "$1"
SH

# Lane stub that fails the way a capped or broken CLI does: its own diagnosis
# on stderr ($1), then a non-zero exit ($2). The child turns that into exit 5
# with a cause block, and the parent must replay it.
cat > "$TMP_ROOT/bin/lane-fail" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
echo "$1" >&2
exit "$2"
SH

# Lane stub that answers with $1 and then removes every directory under the
# sandboxed TMPDIR — the reviewed repo's own agent CLI cleaning temp space
# under the parent, which is what the field report showed. The parent cannot
# reap this lane until the stub exits, so the removal always lands before the
# union step reads anything back.
#
# No -name filter: the parent's promise is that it creates exactly ONE
# directory here and that everything in it is disposable, so the stub tests
# that promise directly. It also must not assume GNU coreutils' `tmp.*`
# mktemp naming, which macOS does not guarantee (this repo supports Bash 3.2 /
# macOS system bash).
#
# $2, when given, is a lane agent name to wait for: the reaper holds until that
# lane's review has landed somewhere in temp space, making "cleared after the
# sibling lane wrote its review, before the parent reaped it" deterministic
# instead of a race. It finds that review wherever the parent chose to put it,
# so the handshake works against the old layout and the new one alike.
cat > "$TMP_ROOT/bin/lane-reap" <<SH
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
cat "\$1"
if [[ \$# -ge 2 ]]; then
  waited=0
  found=""
  while [[ -z "\$found" && \$waited -lt 300 ]]; do
    for f in \$(find "$SCRATCH" -type f 2>/dev/null); do
      if jq -e --arg a "\$2" '.agent == \$a' "\$f" >/dev/null 2>&1; then
        found=1
        break
      fi
    done
    [[ -n "\$found" ]] && break
    sleep 0.1
    waited=\$((waited + 1))
  done
fi
find "$SCRATCH" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} + 2>/dev/null || true
SH

# Lane stub that waits for the sibling lane's artifact ($2) to hold valid JSON,
# sabotages it ($3), and only then answers with $1 — or exits $4 without
# answering, for the every-lane-failed cases. Waiting on the artifact's own
# content is a deterministic handshake, with no sleep-based timing assumption
# and no window where the sibling rewrites what was sabotaged. Actions:
#   steal   remove it — the lane exited 0 but left nothing
#   blank   whitespace: passes a non-empty test, holds no JSON value
#   trunc   a real parse failure, so jq's own message is what gets reported
#   newline a single newline: nothing a shell read can distinguish from empty
#           unless the read preserves the bytes, and the classification must
#           not turn on that
#   nul     a single NUL: a byte no shell string can hold at all, so only a
#           test against the file itself can tell it from an empty artifact
#   nul-tail a complete review with a NUL appended: bytes jq refuses on disk,
#           whose clean prefix is exactly what a shell string would carry
#   unread  replace it with a directory: passes a size test, but no read of it
#           can ever succeed, and no partial bytes may pass for a review
#   double  two concatenated JSON objects — one lane trying to be two
#   poison  parses, top level complete, but a finding is a string — the shape
#           the union merge cannot consume
#   poison-sugg / bad-loc / bad-questions / bad-summary
#           the remaining shapes the merge depends on: it adds {source: …} to
#           every suggestion, lowercases .location, iterates .questions[] and
#           concatenates .summary, so each one aborts the merge if it gets past
#           the gate
cat > "$TMP_ROOT/bin/lane-sabotage" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
resp="$1"; target="$2"; action="$3"; rc="$4"
waited=0
while ! jq -e . < "$target" >/dev/null 2>&1 && [[ $waited -lt 300 ]]; do
  sleep 0.1
  waited=$((waited + 1))
done
head='{"agent":"external-claude","timestamp":"2026-01-01T00:00:00Z","verdict":"pass"'
numloc='{"id":1,"title":"t","description":"d","recommendation":"r","priority":2,"estimate":1,"location":7}'
case "$action" in
  steal)   rm -f -- "$target" ;;
  blank)   printf '   \n' > "$target" ;;
  newline) printf '\n' > "$target" ;;
  nul)     printf '\0' > "$target" ;;
  nul-tail) printf '%s\0' "$head,\"summary\":\"s\",\"blockers\":[],\"suggestions\":[],\"questions\":[],\"qa_metadata\":{}}" > "$target" ;;
  unread)  rm -f -- "$target"; mkdir -p -- "$target" ;;
  trunc)   printf '{"agent":"external-cla' > "$target" ;;
  double)  printf '%s' "$head,\"summary\":\"s\",\"blockers\":[],\"suggestions\":[],\"questions\":[],\"qa_metadata\":{}}$head,\"summary\":\"s\",\"blockers\":[],\"suggestions\":[],\"questions\":[],\"qa_metadata\":{}}" > "$target" ;;
  poison)  printf '%s' "$head,\"summary\":\"s\",\"blockers\":[\"bad\"],\"suggestions\":[],\"questions\":[],\"qa_metadata\":{}}" > "$target" ;;
  poison-sugg)   printf '%s' "$head,\"summary\":\"s\",\"blockers\":[],\"suggestions\":[\"bad\"],\"questions\":[],\"qa_metadata\":{}}" > "$target" ;;
  bad-loc)       printf '%s' "$head,\"summary\":\"s\",\"blockers\":[$numloc],\"suggestions\":[],\"questions\":[],\"qa_metadata\":{}}" > "$target" ;;
  bad-questions) printf '%s' "$head,\"summary\":\"s\",\"blockers\":[],\"suggestions\":[],\"questions\":\"nope\",\"qa_metadata\":{}}" > "$target" ;;
  bad-summary)   printf '%s' "$head,\"summary\":42,\"blockers\":[],\"suggestions\":[],\"questions\":[],\"qa_metadata\":{}}" > "$target" ;;
esac
[[ "$rc" -eq 0 ]] || exit "$rc"
cat "$resp"
SH

# Lane stub that waits until the sibling lane's child has written its raw-
# response sidecar family into the artifact home, records every file across the
# home and temp space that is readable beyond its owner, and only then answers.
# The recording happens while both lanes are still live, which is exactly the
# window in which those files are exposed on a shared host.
#
# It also records HOW MANY files it saw, and fails outright if the handshake
# times out. An empty "loose files" recording otherwise means either "nothing
# was exposed" or "the probe never saw anything", and a renamed sidecar would
# silently turn the permission assertion into a no-op that still passes.
cat > "$TMP_ROOT/bin/lane-probe-perms" <<SH
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
waited=0
seen=""
while [[ \$waited -lt 300 ]]; do
  if [[ -n "\$(find "$ARTIFACT_HOME_DIR" -type f -name '*.raw.txt' 2>/dev/null)" ]]; then
    seen=1
    break
  fi
  sleep 0.1
  waited=\$((waited + 1))
done
if [[ -z "\$seen" ]]; then
  echo "probe stub: no *.raw.txt appeared in the artifact home — handshake never happened" >&2
  exit 1
fi
find "$SCRATCH" "$ARTIFACT_HOME_DIR" -type f 2>/dev/null | wc -l > "$PERM_PROBE.count"
find "$SCRATCH" "$ARTIFACT_HOME_DIR" -type f ! -name .gitignore \( -perm -g+r -o -perm -o+r \) > "$PERM_PROBE" 2>/dev/null || true
cat "\$1"
SH

# Lane stub that leaves an entry inside the parent's scratch directory that the
# parent cannot unlink — a directory it has no write permission on, holding a
# child. That is the reviewed repo's own agent CLI touching scratch, the actor
# from the field report. The parent's `rm -rf` on that directory then fails,
# and inside the EXIT trap that must not decide the run's exit status or skip
# the cleanup that follows it. Deliberately plants no regular file, so the
# leftover assertion still speaks only about what the run itself wrote.
cat > "$TMP_ROOT/bin/lane-plant-locked" <<SH
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
for d in \$(find "$SCRATCH" -mindepth 1 -maxdepth 1 -type d 2>/dev/null); do
  mkdir -p "\$d/locked/inner"
  chmod 500 "\$d/locked"
done
cat "\$1"
SH

# Lane stub that plants a DIRECTORY matching the sibling lane artifact's
# sidecar glob, then answers. The parent's cleanup globs that path at exit;
# rm -f cannot unlink a directory, and a cleanup failure must not be allowed to
# overturn a union both lanes delivered.
cat > "$TMP_ROOT/bin/lane-plant-dir" <<SH
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
waited=0
target=""
while [[ -z "\$target" && \$waited -lt 300 ]]; do
  for f in \$(find "$SCRATCH" -type f 2>/dev/null); do
    if jq -e '.agent // "" | startswith("external-")' "\$f" >/dev/null 2>&1; then
      target="\$f"
      break
    fi
  done
  [[ -n "\$target" ]] && break
  sleep 0.1
  waited=\$((waited + 1))
done
[[ -n "\$target" ]] && mkdir -p "\${target}.evil"
cat "\$1"
SH
# Lane stub that answers with $1 and then removes every regular FILE under $2 —
# a tmp reaper unlinking files rather than the directories `lane-reap` takes,
# the actor a lane review in shared temp space could not survive. $3 is the
# sibling's agent name: the stub holds until that lane's review lands in the
# artifact home, so the clearing is a handshake rather than a race.
cat > "$TMP_ROOT/bin/lane-reap-files" <<SH
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
cat "\$1"
waited=0
found=""
while [[ -z "\$found" && \$waited -lt 300 ]]; do
  for f in \$(find "$ARTIFACT_HOME_DIR" -type f 2>/dev/null); do
    if jq -e --arg a "\$3" '.agent == \$a' "\$f" >/dev/null 2>&1; then
      found=1
      break
    fi
  done
  [[ -n "\$found" ]] && break
  sleep 0.1
  waited=\$((waited + 1))
done
find "\$2" -type f -exec rm -f -- {} + 2>/dev/null || true
SH

# Lane stub that creates the session file and cache directory an external model
# CLI keeps for itself — under $2, prefixed $3 — and then answers with $1.
# Those belong to the CLI, not to this tool, and live outside temp space. $4,
# when given, puts an inode back at an artifact path the parent already cleared:
# the window a mode taken from a survivor leaks through.
cat > "$TMP_ROOT/bin/lane-cli-state" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
mkdir -p -- "$2/$3.cache"
printf 'session\n' > "$2/$3.session"
if [[ $# -ge 4 ]]; then
  printf 'reappeared\n' > "$4"
  chmod 644 -- "$4"
fi
cat "$1"
SH
chmod +x "$TMP_ROOT/bin/lane-answer" "$TMP_ROOT/bin/lane-fail" "$TMP_ROOT/bin/lane-reap" \
  "$TMP_ROOT/bin/lane-sabotage" "$TMP_ROOT/bin/lane-probe-perms" "$TMP_ROOT/bin/lane-plant-dir" \
  "$TMP_ROOT/bin/lane-plant-locked" "$TMP_ROOT/bin/lane-reap-files" \
  "$TMP_ROOT/bin/lane-cli-state"

cat > "$TMP_ROOT/resp-claude.json" <<'JSON'
{"agent":"external-claude","timestamp":"2026-01-01T00:00:00Z","verdict":"action_required",
 "summary":"one blocker",
 "blockers":[{"id":1,"title":"Off-by-one in parse","location":"src/app.rs (`parse`)","description":"d","recommendation":"r","priority":2,"estimate":1}],
 "suggestions":[],"questions":[],"qa_metadata":{}}
JSON

cat > "$TMP_ROOT/resp-codex.json" <<'JSON'
{"agent":"external-codex","timestamp":"2026-01-01T00:00:00Z","verdict":"pass","summary":"clean",
 "blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}
JSON

cat > "$TMP_ROOT/resp-codex-blocker.json" <<'JSON'
{"agent":"external-codex","timestamp":"2026-01-01T00:00:00Z","verdict":"action_required",
 "summary":"one blocker",
 "blockers":[{"id":1,"title":"Unchecked index","location":"src/lib.rs (`get`)","description":"d","recommendation":"r","priority":2,"estimate":1}],
 "suggestions":[],"questions":[],"qa_metadata":{}}
JSON

# Not JSON at all: drives the child's raw-response preservation, so the sidecar
# family lands in temp space beside the stdout-mode lane artifact.
printf 'I am not going to answer in JSON today.\n' > "$TMP_ROOT/resp-prose.txt"

ANSWER_CLAUDE="$TMP_ROOT/bin/lane-answer $TMP_ROOT/resp-claude.json"
ANSWER_CODEX="$TMP_ROOT/bin/lane-answer $TMP_ROOT/resp-codex.json"

# run_lanes <claude-cmd> <codex-cmd> [args...] — always under the sandboxed
# TMPDIR, with both streams captured so stdout-mode unions can be asserted.
# Temp space starts empty so leftovers belong to the run under test.
run_lanes() {
  local claude_cmd="$1" codex_cmd="$2"
  shift 2
  local rc=0
  chmod -R u+rwX "$SCRATCH" 2>/dev/null || true
  rm -rf "$SCRATCH"
  mkdir -p "$SCRATCH"
  rm -f "$PERM_PROBE" "$PERM_PROBE.count"
  set +e
  env TMPDIR="$SCRATCH" PATH="${LANE_TEST_PATH:-$PATH}" \
    SECOND_OPINION_MODELS="codex claude" SECOND_OPINION_COUNT=2 \
    SECOND_OPINION_CLAUDE_CMD="$claude_cmd" \
    SECOND_OPINION_CODEX_CMD="$codex_cmd" \
    "$SECOND_OPINION" review --range HEAD --cwd "$WORK" "$@" \
    >"$TMP_ROOT/last.stdout" 2>"$TMP_ROOT/last.stderr"
  rc=$?
  set -e
  return "$rc"
}

# --- Scenario 1: scratch removed mid-run, --output mode -----------------------
echo "=== scenario 1: scratch dir removed mid-run (--output) -> union still written ==="
out1="$TMP_ROOT/out1.json"
rc1=0
run_lanes "$ANSWER_CLAUDE" "$TMP_ROOT/bin/lane-reap $TMP_ROOT/resp-codex.json" --output "$out1" || rc1=$?
assert_eq "$rc1" "0" "losing scratch does not fail the run"
assert_file_exists "$out1" "union artifact written despite lost scratch"
assert_jq "$out1" '.agent' "external-union(codex+claude)" "both lanes present in the union"
assert_jq "$out1" '.qa_metadata.coverage' "full" "coverage stays full — no lane actually failed"
assert_jq "$out1" '.qa_metadata.lanes | length' "2" "both lanes recorded in qa_metadata.lanes"
assert_jq "$out1" '.blockers | length' "1" "the answering lane's finding survives into the union"
assert_stderr_lacks "unusable artifact" "a lost scratch file is not called an unusable artifact"
assert_stderr_has "lane stderr replay unavailable" "the lost stderr replay is reported honestly"
assert_stderr_has "(union of 2 lanes)" "the reported lane count comes from the artifact's own ok lanes"
assert_file_exists "$out1.codex.json" "codex lane artifact kept beside the union"
assert_file_exists "$out1.claude.json" "claude lane artifact kept beside the union"

# --- Scenario 2: scratch removed mid-run, stdout mode -------------------------
# Same durability contract with no --output: the lane reviews must not live in
# the directory the parent advertises as disposable, or clearing it drops a
# model's real findings while the union still publishes a verdict.
echo "=== scenario 2: scratch dir removed mid-run (stdout) -> union still printed ==="
rc2=0
run_lanes "$ANSWER_CLAUDE" \
  "$TMP_ROOT/bin/lane-reap $TMP_ROOT/resp-codex.json external-claude" || rc2=$?
union2="$TMP_ROOT/last.stdout"
assert_eq "$rc2" "0" "stdout mode survives losing scratch"
assert_jq "$union2" '.agent' "external-union(codex+claude)" "stdout union carries both lanes"
assert_jq "$union2" '.qa_metadata.coverage' "full" "stdout union coverage stays full"
assert_jq "$union2" '.blockers | length' "1" "stdout union keeps the answering lane's blocker"
assert_jq "$union2" '.verdict' "action_required" "stdout union verdict follows the surviving blocker"
assert_stderr_lacks "unusable artifact" "stdout mode does not call a lost scratch file unusable"
assert_no_leftovers "stdout-mode temp space is left clean"

# --- Scenario 3: clean exit with no usable artifact is not "exit 0" -----------
# A lane whose artifact is gone by the time it is reaped never delivered an
# answer — a lane-level failure. It must be recorded with a truthful code, not
# the bare "exit 0" the reaped child happened to return.
echo "=== scenario 3: lane exits 0 with no artifact -> truthful failure code ==="
out3="$TMP_ROOT/out3.json"
rc3=0
run_lanes "$ANSWER_CLAUDE" \
  "$TMP_ROOT/bin/lane-sabotage $TMP_ROOT/resp-codex.json $out3.claude.json steal 0" \
  --output "$out3" || rc3=$?
assert_eq "$rc3" "0" "the surviving lane keeps the run at exit 0"
assert_jq "$out3" '.qa_metadata.coverage' "degraded" "the lost lane degrades coverage"
assert_jq "$out3" '[.qa_metadata.lanes[] | select(.target == "claude")][0].exit_code' "5" \
  "the lost lane records the never-answered code, not 0"
assert_stderr_has "without a usable artifact" "the missing artifact is named as the cause"
assert_stderr_lacks "(exit 0)" "a failed lane is never reported as exit 0"
assert_stderr_has "(union of 1 lanes)" "the reported count drops the failed lane"

# --- Scenario 4: an artifact holding no JSON value is unusable ----------------
# jq exits 0 and prints NOTHING for a whitespace-only artifact, which passes a
# non-empty file test. Accepting that as a lane would count it healthy while it
# contributes no findings — the union would publish a pass over a real blocker.
echo "=== scenario 4: blanked artifact -> unusable lane, surviving findings kept ==="
out4="$TMP_ROOT/out4.json"
rc4=0
run_lanes "$ANSWER_CLAUDE" \
  "$TMP_ROOT/bin/lane-sabotage $TMP_ROOT/resp-codex-blocker.json $out4.claude.json blank 0" \
  --output "$out4" || rc4=$?
assert_eq "$rc4" "0" "one unusable lane does not fail the run"
assert_file_exists "$out4" "union artifact still written"
assert_jq "$out4" '.qa_metadata.coverage' "degraded" "the valueless artifact degrades coverage"
assert_jq "$out4" '[.qa_metadata.lanes[] | select(.target == "claude")][0].exit_code' "4" \
  "a lane that answered unusably records 4"
assert_jq "$out4" '.qa_metadata.lanes | length' "2" "the unusable lane is still accounted for"
assert_jq "$out4" '.blockers | length' "1" "the surviving lane's blocker reaches the union"
assert_jq "$out4" '.verdict' "action_required" "the union verdict follows the surviving blocker"
assert_stderr_has "unusable artifact: claude" "the valueless artifact is named unusable"
assert_stderr_has "holds no JSON value at all" "the unusable artifact's cause is reported"
assert_stderr_has "(union of 1 lanes)" "the count matches the one lane the artifact carries"

# --- Scenario 5: every lane fails, none ever answered -> exit 5 ---------------
# The aggregate exit code is decided by whether any lane ANSWERED unusably. A
# lane that exited 0 with no artifact never answered, so it must leave the
# aggregate at 5 — repointing that branch to 4 would silently change this
# contract with every other test still green.
echo "=== scenario 5: no lane ever answered -> exit 5, no artifact ==="
out5="$TMP_ROOT/out5.json"
rc5=0
run_lanes "$ANSWER_CLAUDE" \
  "$TMP_ROOT/bin/lane-sabotage $TMP_ROOT/resp-codex.json $out5.claude.json steal 1" \
  --output "$out5" || rc5=$?
assert_eq "$rc5" "5" "all lanes lost with none answering exits 5"
assert_file_absent "$out5" "no union artifact when every lane failed"
assert_stderr_has "every review lane failed" "the no-verdict condition is reported"
assert_stderr_has "lane failed: codex (exit 5)" "the failed CLI lane records 5"
assert_stderr_has "lane failed: claude (exit 5)" "the artifact-less lane records 5"

# --- Scenario 6: every lane fails, one answered unusably -> exit 4 ------------
echo "=== scenario 6: some lane answered unusably -> exit 4, no artifact ==="
out6="$TMP_ROOT/out6.json"
rc6=0
run_lanes "$ANSWER_CLAUDE" \
  "$TMP_ROOT/bin/lane-sabotage $TMP_ROOT/resp-codex.json $out6.claude.json blank 1" \
  --output "$out6" || rc6=$?
assert_eq "$rc6" "4" "an unusable answer moves the aggregate to 4"
assert_file_absent "$out6" "no union artifact when every lane failed"
assert_stderr_has "lane failed: claude (exit 4)" "the unusable lane records 4"

# --- Scenario 7: the lane logs reach the operator -----------------------------
# The parent's replay is the ONLY view an operator has of what a lane did. It
# is on the success path, so nothing else in this suite would notice it being
# swallowed — a redirection written in the wrong order sends every lane's log
# to /dev/null while every other assertion still passes.
echo "=== scenario 7: healthy lanes -> both logs replayed, artifacts owner-only ==="
out7="$TMP_ROOT/out7.json"
# A reused --output path can already carry a lane family from an earlier run.
# The umask governs only files a child CREATES: writing through a surviving
# inode keeps that inode's mode, so a stale 0644 artifact would stay
# world-readable through every later run against the same path.
printf 'stale\n' > "$out7.codex.json"
printf 'stale raw response\n' > "$out7.codex.json.raw.txt"
chmod 644 "$out7.codex.json" "$out7.codex.json.raw.txt"
# The output path belongs to the caller, not to this tool: clearing the lane's
# own family must not take anything else of theirs sitting under that prefix.
printf 'my own notes\n' > "$out7.codex.json.notes"
rc7=0
run_lanes "$ANSWER_CLAUDE" "$ANSWER_CODEX" --output "$out7" || rc7=$?
assert_eq "$rc7" "0" "two healthy lanes exit 0"
assert_jq "$out7" '.qa_metadata.coverage' "full" "two healthy lanes are full coverage"
assert_stderr_has "[codex] " "the codex lane's log is replayed, lane-prefixed"
assert_stderr_has "[claude] " "the claude lane's log is replayed, lane-prefixed"
assert_owner_only "$out7.codex.json" "the codex lane artifact is owner-only"
assert_owner_only "$out7.claude.json" "the claude lane artifact is owner-only"
assert_file_absent "$out7.codex.json.raw.txt" "a previous run's lane sidecar does not survive"
assert_file_exists "$out7.codex.json.notes" "an unrelated caller file under the same prefix survives"

# --- Scenario 8: a failing lane's own cause text survives ---------------------
# review-pr documents the replayed cause as how an operator diagnoses exit 5.
# Without it the whole operator-visible output of a capped lane is a bare
# "lane failed: codex (exit 5)".
echo "=== scenario 8: failing lane -> its CLI's own error text reaches the parent ==="
out8="$TMP_ROOT/out8.json"
rc8=0
run_lanes "$ANSWER_CLAUDE" "$TMP_ROOT/bin/lane-fail QUOTA-EXCEEDED-XYZ 1" --output "$out8" || rc8=$?
assert_eq "$rc8" "0" "the surviving lane keeps the run at exit 0"
assert_jq "$out8" '.qa_metadata.coverage' "degraded" "the failed lane degrades coverage"
assert_stderr_has "[codex] " "the failing lane's log is replayed, lane-prefixed"
assert_stderr_has "QUOTA-EXCEEDED-XYZ" "the CLI's own cause text reaches the parent"
assert_stderr_has "lane failed: codex (exit 5)" "the failed lane is recorded"

# --- Scenario 9: a finding the merge cannot consume ---------------------------
# Schema-complete at the top level, but `blockers: ["bad"]`. It parses, so the
# wrap used to accept it — and then the union merge aborted on it under set -e,
# delivering NO union at all even though the other lane was perfect. The same
# harm as the original bug, fail-closed instead of fail-open.
echo "=== scenario 9: malformed finding -> that lane is unusable, the union still ships ==="
out9="$TMP_ROOT/out9.json"
rc9=0
run_lanes "$ANSWER_CLAUDE" \
  "$TMP_ROOT/bin/lane-sabotage $TMP_ROOT/resp-codex-blocker.json $out9.claude.json poison 0" \
  --output "$out9" || rc9=$?
assert_eq "$rc9" "0" "one merge-hostile lane does not fail the run"
assert_file_exists "$out9" "the union still ships"
assert_jq "$out9" '.qa_metadata.coverage' "degraded" "the merge-hostile lane degrades coverage"
assert_jq "$out9" '[.qa_metadata.lanes[] | select(.target == "claude")][0].exit_code' "4" \
  "the merge-hostile lane records 4"
assert_jq "$out9" '.blockers | length' "1" "the healthy lane's blocker still reaches the union"
assert_jq "$out9" '.blockers[0].title' "Unchecked index" "and it is the healthy lane's own finding"
assert_stderr_has "holds a non-object entry" "the rejected shape is named"

# --- Scenario 10: a truncated artifact reports jq's own reason ----------------
# The fallback string is what gets printed when the cause capture comes back
# empty — so a scenario that only asserts the fallback cannot tell a working
# capture from a permanently empty one. This one requires jq's real wording and
# forbids the fallback.
echo "=== scenario 10: truncated artifact -> the real parse error is reported ==="
out10="$TMP_ROOT/out10.json"
rc10=0
run_lanes "$ANSWER_CLAUDE" \
  "$TMP_ROOT/bin/lane-sabotage $TMP_ROOT/resp-codex-blocker.json $out10.claude.json trunc 0" \
  --output "$out10" || rc10=$?
assert_eq "$rc10" "0" "a truncated lane does not fail the run"
assert_jq "$out10" '.qa_metadata.coverage' "degraded" "the truncated lane degrades coverage"
assert_jq "$out10" '[.qa_metadata.lanes[] | select(.target == "claude")][0].exit_code' "4" \
  "the truncated lane records 4"
assert_jq "$out10" '.blockers | length' "1" "the surviving lane's findings still reach the union"
assert_stderr_has "parse error" "jq's own wording is reported as the cause"
assert_stderr_lacks "no JSON value in artifact" "the fallback string is not used when jq had a reason"

# --- Scenario 11: sidecars in temp space are owner-only and cleaned up --------
# A lane whose model answers in prose makes the child preserve the raw response
# beside the artifact it was handed — in stdout mode, in the TMPDIR root. Those
# files carry the model's review text, and the parent is responsible for both
# their permissions and their removal.
echo "=== scenario 11: stdout-mode sidecars -> owner-only while live, gone after ==="
rc11=0
run_lanes "$TMP_ROOT/bin/lane-probe-perms $TMP_ROOT/resp-claude.json" \
  "$TMP_ROOT/bin/lane-answer $TMP_ROOT/resp-prose.txt" || rc11=$?
assert_eq "$rc11" "0" "the surviving lane keeps the run at exit 0"
assert_jq "$TMP_ROOT/last.stdout" '.qa_metadata.coverage' "degraded" "the prose lane degrades coverage"
assert_jq "$TMP_ROOT/last.stdout" '.blockers | length' "1" "the answering lane's blocker still ships"
assert_probe_saw_files "$PERM_PROBE.count" "the permission probe actually observed temp files"
assert_probe_empty "$PERM_PROBE" "no temp file is readable beyond its owner while lanes are live"
assert_no_leftovers "the lane artifact and its sidecar family are both cleaned up"

# --- Scenario 12: cleanup cannot overturn a delivered union -------------------
# rm -f fails on an entry it cannot unlink, and this cleanup runs in the EXIT
# trap: a planted directory in the sidecar glob's path would otherwise turn a
# complete two-lane union into a non-zero exit, and a caller checking status
# would discard a verdict both models delivered.
echo "=== scenario 12: an unremovable entry in cleanup -> run still exits 0 ==="
rc12=0
run_lanes "$ANSWER_CLAUDE" "$TMP_ROOT/bin/lane-plant-dir $TMP_ROOT/resp-codex.json" || rc12=$?
assert_eq "$rc12" "0" "a cleanup that cannot unlink an entry does not fail the run"
assert_jq "$TMP_ROOT/last.stdout" '.agent' "external-union(codex+claude)" "the union is still delivered"
assert_jq "$TMP_ROOT/last.stdout" '.blockers | length' "1" "with both lanes' findings"

# --- Scenario 13: every clause of the artifact gate -------------------------
# The gate refuses several distinct shapes and each one is load-bearing: past
# the gate, the merge adds {source: …} to every blocker AND suggestion,
# lowercases .location, iterates .questions[] and concatenates .summary — so a
# clause that stops firing costs the whole union, not just its lane. Each is
# pinned to its own message so a clause cannot be covered by its neighbour.
echo "=== scenario 13: each artifact-gate clause rejects its own shape ==="
# assert_gate_rejects <label> <sabotage-action> <expected cause fragment>
assert_gate_rejects() {
  local label="$1" action="$2" cause="$3" out rc=0
  out="$TMP_ROOT/out-$label.json"
  run_lanes "$ANSWER_CLAUDE" \
    "$TMP_ROOT/bin/lane-sabotage $TMP_ROOT/resp-codex-blocker.json $out.claude.json $action 0" \
    --output "$out" || rc=$?
  assert_eq "$rc" "0" "$label: the run still exits 0"
  assert_jq "$out" '.blockers | length' "1" "$label: the healthy lane's blocker still ships"
  assert_jq "$out" '.qa_metadata.coverage' "degraded" "$label: coverage degrades"
  assert_jq "$out" '[.qa_metadata.lanes[] | select(.target == "claude")][0].exit_code' "4" \
    "$label: the rejected lane records 4"
  assert_stderr_has "$cause" "$label: the rejected clause names itself"
}
assert_gate_rejects "suggestions" poison-sugg "suggestions holds a non-object entry"
assert_gate_rejects "location" bad-loc "blockers holds a non-string location"
assert_gate_rejects "questions" bad-questions "questions is not an array"
assert_gate_rejects "summary" bad-summary "summary is not a string"
# A newline-only artifact must reach the gate like any other malformed shape,
# not read back as "nothing was there" through a shell that strips newlines.
assert_gate_rejects "newline" newline "holds no JSON value at all"
# Same rule, one byte further out: a NUL cannot live in a shell string at all,
# so a lane that wrote one is only distinguishable from a lane that wrote
# nothing by asking the file. It answered — unusably — and must record 4, with
# the parse error the bytes themselves earn.
assert_gate_rejects "nul" nul "Invalid numeric literal"
# The case a dropped NUL would hide: a complete review with a NUL appended is
# bytes jq refuses, but its clean prefix parses. Read through a shell string the
# lane is counted healthy and coverage still reads "full" over an artifact no
# reader would accept, so the refusal here is the whole point of the gate.
assert_gate_rejects "nul-tail" nul-tail "Invalid numeric literal"
assert_jq "$TMP_ROOT/out-nul-tail.json" '.agent' "external-union(codex)" \
  "nul-tail: the union carries only the lane whose bytes parse"
# The read itself can fail, and the sentinel that preserves trailing newlines
# also makes the substitution's exit status permanently 0, so nothing downstream
# can ask whether the read finished. The guard is to append a byte jq refuses
# whenever it did not, which puts every failed read in answered-unusably no
# matter what bytes it managed to emit first. A directory in the artifact's
# place passes the size test and can never be read at all: that pins the guard
# firing and the cause it reports. The case it exists for — a read that emits a
# prefix which parses on its own before failing — needs a mid-read I/O error
# this suite cannot construct portably, so the guard is verified here by the
# path it shares with that case, not by the case itself.
# The plant rests on a directory reporting a non-zero size, a filesystem
# property: ext4 gives 4096, btrfs and some tmpfs give 0. Where it gives 0 it is
# indistinguishable from an artifact never written, so the case is skipped.
unread_probe="$TMP_ROOT/unread-probe"
mkdir -p "$unread_probe"
if [[ -s "$unread_probe" ]]; then
  assert_gate_rejects "unread" unread "Invalid numeric literal"
  assert_jq "$TMP_ROOT/out-unread.json" '.agent' "external-union(codex)" \
    "unread: an artifact nobody could read is not a healthy lane"
else
  skip "unread: a directory reports size 0 on this filesystem, so a path that passes the size test yet can never be read cannot be built here"
fi
rmdir "$unread_probe"
# Bash 4.4+ warns about NUL bytes it dropped from a command substitution. No
# NUL now reaches a shell string, so the warning has no occasion to fire — and
# it never named a lane or told an operator anything they could act on, while
# the rejection line beside it names both.
assert_stderr_lacks "ignored null byte" "the shell's own NUL warning does not reach the operator"
# One lane may not smuggle in a second review: without the refusal the first
# value is silently accepted, the second dropped, and coverage still reads full.
assert_gate_rejects "twovalues" double "holds 2 JSON values, expected one"
assert_jq "$TMP_ROOT/out-twovalues.json" '.agent' "external-union(codex)" \
  "twovalues: the union carries only the lanes that answered once"

# --- Scenario 14: an unremovable entry inside the scratch directory ----------
# Same rule as scenario 12, one line earlier in the same trap: `rm -rf` on the
# scratch directory fails when something inside it cannot be unlinked, and that
# failure would both decide the run's exit status and skip the artifact cleanup
# that follows it in the trap.
echo "=== scenario 14: unremovable scratch entry -> exit 0, cleanup still runs ==="
# The hazard rests on mode bits, and mode bits do not stop root: on a
# privileged runner — a root CI container — the plant is removable, the
# parent's removal succeeds, and every assertion here becomes meaningless.
# Build the same shape on a throwaway copy first and see whether it actually
# resists removal. If it does not, this runner cannot construct the hazard at
# all, so the scenario is skipped with its reason rather than passed (which
# would hide the coverage loss) or failed (which would break a runner for a
# property it cannot express).
hazard_probe="$TMP_ROOT/hazard-probe"
rm -rf "$hazard_probe" 2>/dev/null || true
mkdir -p "$hazard_probe/locked/inner"
chmod 500 "$hazard_probe/locked"
hazard_rc=0
rm -rf "$hazard_probe" 2>/dev/null || hazard_rc=$?
chmod -R u+rwX "$hazard_probe" 2>/dev/null || true
rm -rf "$hazard_probe" 2>/dev/null || true

if [[ "$hazard_rc" -eq 0 ]]; then
  skip "scenario 14: a 0500 directory holding a child is removable by this user (effectively privileged), so the unremovable-entry hazard cannot be built and the cleanup guard goes unproven here"
else
  pass "the planted shape is genuinely unremovable by this user"
  rc14=0
  run_lanes "$ANSWER_CLAUDE" "$TMP_ROOT/bin/lane-plant-locked $TMP_ROOT/resp-codex.json" || rc14=$?
  assert_eq "$rc14" "0" "a scratch directory that cannot be removed does not fail the run"
  assert_jq "$TMP_ROOT/last.stdout" '.agent' "external-union(codex+claude)" "the union is still delivered"
  assert_no_leftovers "the trap reached the artifact cleanup below the failing removal"
  planted_name="the hazard was actually planted in the run's scratch directory"
  if [[ -n "$(find "$SCRATCH" -type d -name locked 2>/dev/null | head -1 || true)" ]]; then
    pass "$planted_name"
  else
    fail "$planted_name"
    printf '        nothing survived the parent removal — the stub planted nothing to block it\n' >&2
  fi
fi

# --- Scenario 15: an --output value that begins with a dash ------------------
# --output is caller input. A bare `-name.json` is a valid path and an invalid
# option, so the pre-spawn cleanup utilities must be told where their options
# end — otherwise the run dies before a single lane spawns and the stale-
# artifact cleanup those lines exist for never happens.
#
# A bare `-dashed.json` — no `./` to hide the leading dash — has to work end to
# end: the parent's own preflight, and every path the recursive lane child
# derives from the same value while writing its artifact and sidecars. Passed in
# the `=` form, which is how a dash-leading value is supplied now that the split
# form refuses a flag-shaped token; the parent hands its children the same form
# for exactly that reason.
echo "=== scenario 15: a dashed --output works end to end ==="
rc15=0
( cd "$TMP_ROOT" && run_lanes "$ANSWER_CLAUDE" "$ANSWER_CODEX" --output=-dashed.json ) || rc15=$?
dashed="$TMP_ROOT/-dashed.json"
assert_eq "$rc15" "0" "a dashed --output value does not fail the run"
assert_stderr_has "[codex] " "lanes still run when --output begins with a dash"
assert_stderr_has "[claude] " "both lanes are reached"
assert_file_exists "$dashed" "the union is written to the dashed path"
assert_jq "$dashed" '.qa_metadata.coverage' "full" "both lanes answered through the dashed path"
assert_jq "$dashed" '.blockers | length' "1" "the union carries the lane's blocker"
assert_file_exists "$dashed.claude.json" "the lane artifact is written beside the dashed union"

# --- Scenario 16: the stderr capture cannot cost a lane its verdict ----------
# A redirection named on the launch is performed by the forked child before the
# command runs, so an unusable capture target kills the lane outright: no
# review, no artifact, the lane recorded as failed, and its blockers missing
# from a union that still publishes. That makes scratch loss cost a VERDICT,
# which is precisely what this skill promises it cannot.
#
# Driven deterministically rather than by racing the fan-out: a mktemp shim
# fixes the scratch directory's path so an unusable capture target — a
# directory where the lane wants a file — can be planted before the run. Same
# failure the vanishing directory produces at the same moment, without a timing
# assumption.
echo "=== scenario 16: an unusable stderr capture costs the log, never the lane ==="
mkdir -p "$TMP_ROOT/shimbin"
REAL_MKTEMP="$(command -v mktemp)"
FIXED_SCRATCH="$TMP_ROOT/fixed-scratch"
cat > "$TMP_ROOT/shimbin/mktemp" <<SH
#!/usr/bin/env bash
# Only 'mktemp -d' is answered with the fixed path; every other call defers to
# the real mktemp, resolved absolutely so this shim cannot recurse into itself.
set -euo pipefail
for a in "\$@"; do
  if [[ "\$a" == "-d" ]]; then
    mkdir -p "$FIXED_SCRATCH"
    printf '%s\n' "$FIXED_SCRATCH"
    exit 0
  fi
done
exec "$REAL_MKTEMP" "\$@"
SH
chmod +x "$TMP_ROOT/shimbin/mktemp"
rm -rf "$FIXED_SCRATCH"
mkdir -p "$FIXED_SCRATCH/lane-claude.stderr"
out16="$TMP_ROOT/out16.json"
rc16=0
LANE_TEST_PATH="$TMP_ROOT/shimbin:$PATH"
run_lanes "$ANSWER_CLAUDE" "$ANSWER_CODEX" --output "$out16" || rc16=$?
LANE_TEST_PATH=""
assert_eq "$rc16" "0" "an unusable capture does not fail the run"
assert_file_exists "$out16" "the union is still written"
assert_jq "$out16" '.qa_metadata.coverage' "full" "no lane is lost to its capture"
assert_jq "$out16" '[.qa_metadata.lanes[] | select(.target == "claude")][0].status' "ok" \
  "the affected lane answered — not recorded as failed"
assert_jq "$out16" '.blockers | length' "1" "the affected lane's blocker reaches the union"
assert_stderr_has "capture could not be opened" "the lost capture is reported on stderr"

# --- Scenario 17: a reaper that removes temp FILES ---------------------------
# The stdout-mode residual: while a lane's review sat in shared temp space, an
# actor unlinking temp FILES — rather than the one directory the run creates
# there — still cost that lane its findings. The review is in the artifact home
# now, so the same actor costs the log replay and nothing else.
echo "=== scenario 17: temp FILES removed mid-run (stdout) -> union intact ==="
rc17=0
run_lanes "$ANSWER_CLAUDE" \
  "$TMP_ROOT/bin/lane-reap-files $TMP_ROOT/resp-codex.json $SCRATCH external-claude" || rc17=$?
assert_eq "$rc17" "0" "a temp-file reaper does not fail the run"
assert_jq "$TMP_ROOT/last.stdout" '.agent' "external-union(codex+claude)" "both lanes reach the union"
assert_jq "$TMP_ROOT/last.stdout" '.qa_metadata.coverage' "full" "no lane is lost to a temp-file reaper"
assert_jq "$TMP_ROOT/last.stdout" '.blockers | length' "1" "the reaped-past lane's blocker survives"
assert_stderr_has "lane stderr replay unavailable" "the reaper did land — the replay is what it cost"
assert_no_leftovers "the run still leaves nothing behind"

# --- Scenario 18: the same reaper, pointed at the artifact home --------------
# The control for 17: an actor that reaches the home DOES cost that lane, which
# is what proves the reaper removes files at all and that the review is in the
# home — without it, 17 passes for a reaper that never worked.
echo "=== scenario 18: the artifact home reaped -> that lane is lost, loudly ==="
rc18=0
run_lanes "$ANSWER_CLAUDE" \
  "$TMP_ROOT/bin/lane-reap-files $TMP_ROOT/resp-codex.json $ARTIFACT_HOME_DIR external-claude" || rc18=$?
assert_eq "$rc18" "0" "the surviving lane keeps the run at exit 0"
assert_jq "$TMP_ROOT/last.stdout" '.qa_metadata.coverage' "degraded" "the lost lane degrades coverage"
assert_jq "$TMP_ROOT/last.stdout" '.blockers | length' "0" "its findings go with it"
assert_stderr_has "without a usable artifact" "the loss is named on stderr"

# --- Scenario 19: the restriction rides on the writes, not on the lane -------
# A umask on the lane process governs everything the external model CLI creates
# for the life of that lane — the session and cache state it keeps outside temp
# space included, where whichever mode created a shared one fixes its
# permissions permanently. Lane artifacts stay owner-only, through a reappeared
# inode too; the CLI's own files come out as they do single-lane. Each half is
# the other's control.
echo "=== scenario 19: lane artifacts owner-only, the CLI's own files are not ==="
STATE="$TMP_ROOT/cli-state"
rm -rf "$STATE"
mkdir -p "$STATE"
out19="$TMP_ROOT/out19.json"
rc19=0
( umask 022
  run_lanes "$TMP_ROOT/bin/lane-cli-state $TMP_ROOT/resp-claude.json $STATE multi-claude $out19.claude.json" \
    "$TMP_ROOT/bin/lane-cli-state $TMP_ROOT/resp-codex.json $STATE multi-codex $out19.codex.json" \
    --output "$out19" ) || rc19=$?
assert_eq "$rc19" "0" "both lanes answered"
assert_owner_only "$out19.claude.json" "the claude lane artifact is owner-only through a reappeared inode"
assert_owner_only "$out19.codex.json" "the codex lane artifact is owner-only through a reappeared inode"
assert_group_other_readable "$STATE/multi-claude.session" "the claude CLI's own session file keeps the caller's umask"
assert_group_other_readable "$STATE/multi-claude.cache" "the claude CLI's own cache directory keeps the caller's umask"
assert_group_other_readable "$STATE/multi-codex.session" "the codex CLI's own session file keeps the caller's umask"
assert_group_other_readable "$STATE/multi-codex.cache" "the codex CLI's own cache directory keeps the caller's umask"
# The comparison the report was made with: single-lane never had a process
# umask, so its result is what the CLI's own files are supposed to look like.
# The caller's --output is theirs too, in either mode.
single19="$TMP_ROOT/out19-single.json"
( umask 022
  env TMPDIR="$SCRATCH" SECOND_OPINION_MODELS="codex" SECOND_OPINION_COUNT=1 \
    SECOND_OPINION_CODEX_CMD="$TMP_ROOT/bin/lane-cli-state $TMP_ROOT/resp-codex.json $STATE single" \
    "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$single19" ) >/dev/null 2>&1
assert_group_other_readable "$STATE/single.session" "single-lane leaves the CLI's session file the same way"
assert_group_other_readable "$STATE/single.cache" "single-lane leaves the CLI's cache directory the same way"
assert_group_other_readable "$single19" "a caller's own --output follows the caller's umask"

echo
printf 'pass: %d   fail: %d   skip: %d\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]
