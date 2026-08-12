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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
# A scenario below deliberately leaves a directory the run cannot write into,
# so make the tree removable before removing it.
trap 'chmod -R u+rwX "$TMP_ROOT" 2>/dev/null; rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/proj/skills"
git init -q "$TMP_ROOT/proj"
cp -R "$REPO_ROOT/skills/second-opinion" "$TMP_ROOT/proj/skills/second-opinion"
SECOND_OPINION="$TMP_ROOT/proj/skills/second-opinion/scripts/second-opinion"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }

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

# Nothing the run caused to be written may survive in temp space — not the
# lane artifact, not the sidecar family a lane child writes beside it. The
# parent's promise is "leaves nothing behind", so the predicate is any regular
# file at all; the jq probe only enriches the failure message.
assert_no_leftovers() {
  local name="$1" leftover detail=""
  leftover="$(find "$SCRATCH" -type f 2>/dev/null | head -1 || true)"
  if [[ -n "$leftover" ]]; then
    if jq -e '.agent // "" | startswith("external-")' "$leftover" >/dev/null 2>&1; then
      detail=" (a lane review)"
    fi
    fail "$name"
    printf '        left behind in temp space%s: %s\n' "$detail" "$leftover" >&2
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
while ! jq -e . "$target" >/dev/null 2>&1 && [[ $waited -lt 300 ]]; do
  sleep 0.1
  waited=$((waited + 1))
done
head='{"agent":"external-claude","timestamp":"2026-01-01T00:00:00Z","verdict":"pass"'
numloc='{"id":1,"title":"t","description":"d","recommendation":"r","priority":2,"estimate":1,"location":7}'
case "$action" in
  steal)   rm -f "$target" ;;
  blank)   printf '   \n' > "$target" ;;
  newline) printf '\n' > "$target" ;;
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
# response sidecar family into temp space, records every file there that is
# readable beyond its owner, and only then answers. The recording happens while
# both lanes are still live, which is exactly the window in which those files
# are exposed on a shared host.
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
  if [[ -n "\$(find "$SCRATCH" -type f -name '*.raw.txt' 2>/dev/null)" ]]; then
    seen=1
    break
  fi
  sleep 0.1
  waited=\$((waited + 1))
done
if [[ -z "\$seen" ]]; then
  echo "probe stub: no *.raw.txt appeared in temp space — handshake never happened" >&2
  exit 1
fi
find "$SCRATCH" -type f 2>/dev/null | wc -l > "$PERM_PROBE.count"
find "$SCRATCH" -type f \( -perm -g+r -o -perm -o+r \) > "$PERM_PROBE" 2>/dev/null || true
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
chmod +x "$TMP_ROOT/bin/lane-answer" "$TMP_ROOT/bin/lane-fail" "$TMP_ROOT/bin/lane-reap" \
  "$TMP_ROOT/bin/lane-sabotage" "$TMP_ROOT/bin/lane-probe-perms" "$TMP_ROOT/bin/lane-plant-dir" \
  "$TMP_ROOT/bin/lane-plant-locked"

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
  env TMPDIR="$SCRATCH" \
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
rc7=0
run_lanes "$ANSWER_CLAUDE" "$ANSWER_CODEX" --output "$out7" || rc7=$?
assert_eq "$rc7" "0" "two healthy lanes exit 0"
assert_jq "$out7" '.qa_metadata.coverage' "full" "two healthy lanes are full coverage"
assert_stderr_has "[codex] " "the codex lane's log is replayed, lane-prefixed"
assert_stderr_has "[claude] " "the claude lane's log is replayed, lane-prefixed"
assert_owner_only "$out7.codex.json" "the codex lane artifact is owner-only"
assert_owner_only "$out7.claude.json" "the claude lane artifact is owner-only"

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
rc14=0
run_lanes "$ANSWER_CLAUDE" "$TMP_ROOT/bin/lane-plant-locked $TMP_ROOT/resp-codex.json" || rc14=$?
assert_eq "$rc14" "0" "a scratch directory that cannot be removed does not fail the run"
assert_jq "$TMP_ROOT/last.stdout" '.agent' "external-union(codex+claude)" "the union is still delivered"
assert_no_leftovers "the trap reached the artifact cleanup below the failing removal"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
