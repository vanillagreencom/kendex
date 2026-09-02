#!/usr/bin/env bash
# Regression tests for approval-wait's pre-poll CLI layer, split from
# approval_wait.sh at this seam (the wait-loop suites live there; nothing
# here polls — every case terminates before the first gh call):
#   - --resolve-mode precedence: PR_REVIEW_GATE / legacy PR_APPROVAL_GATE /
#     REVIEW_GATE_MODE, settings-file resolution, and the engine-only
#     dotenv boundary (PR #1615)
#   - -h/--help and unknown-flag argument parsing (kendex#981, KEN-556)
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

dump_stderr() {
  local file="$1"
  [[ -n "$file" && -f "$file" ]] || return 0
  printf '        stderr:\n'
  sed 's/^/          /' "$file"
}

assert_eq() {
  local got="$1" want="$2" name="$3" stderr_file="${4:-}"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
    dump_stderr "$stderr_file"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3" stderr_file="${4:-}"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
    dump_stderr "$stderr_file"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3" stderr_file="${4:-}"
  if grep -qF -- "$needle" <<<"$haystack"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        forbidden substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
    dump_stderr "$stderr_file"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

mkdir -p "$TMP_ROOT/repo/.agents/skills"
ln -s "$REPO_ROOT/skills/orch" "$TMP_ROOT/repo/.agents/skills/orch"
# review-gate too: --resolve-mode reads REVIEW_GATE_MODE through that
# skill's own settings resolver when it is installed.
ln -s "$REPO_ROOT/skills/review-gate" "$TMP_ROOT/repo/.agents/skills/review-gate"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config user.email test@example.com
git -C "$TMP_ROOT/repo" config user.name Test

# Call-recording gh stub: every case here terminates in the parser or the
# config resolver, so ANY gh invocation is a failure the log makes visible.
mkdir -p "$TMP_ROOT/argbin"
cat > "$TMP_ROOT/argbin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/argval-gh.calls"
exit 1
EOF
chmod +x "$TMP_ROOT/argbin/gh"

run_resolve_mode() {
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/argbin:$PATH" \
       env "$@" .agents/skills/orch/scripts/approval-wait --resolve-mode)
}

echo "=== approval-wait --resolve-mode precedence ==="

# PR_REVIEW_GATE wins outright, including over a conflicting legacy value.
assert_eq "$(run_resolve_mode PR_REVIEW_GATE=review)" "review" "resolve: PR_REVIEW_GATE=review"
assert_eq "$(run_resolve_mode PR_REVIEW_GATE=off)" "off" "resolve: PR_REVIEW_GATE=off"
assert_eq "$(run_resolve_mode PR_REVIEW_GATE=approval)" "approval" "resolve: PR_REVIEW_GATE=approval"
assert_eq "$(run_resolve_mode PR_REVIEW_GATE=review PR_APPROVAL_GATE=off)" "review" "resolve: PR_REVIEW_GATE beats legacy PR_APPROVAL_GATE"

# Legacy derivation when PR_REVIEW_GATE is unset: on -> approval, off -> off.
assert_eq "$(run_resolve_mode PR_APPROVAL_GATE=on)" "approval" "resolve: legacy on maps to approval"
assert_eq "$(run_resolve_mode PR_APPROVAL_GATE=off)" "off" "resolve: legacy off maps to off"

# Both unset defaults to approval.
assert_eq "$(run_resolve_mode)" "approval" "resolve: default approval"

# An unrecognized PR_REVIEW_GATE fails safe to approval (gate stays on).
assert_eq "$(run_resolve_mode PR_REVIEW_GATE=bogus 2>/dev/null)" "approval" "resolve: invalid value falls back to approval"

# kendex.settings.toml [env] is read with orch-env precedence: the settings
# value applies when the process env is silent, and process env wins over it.
cat > "$TMP_ROOT/repo/kendex.settings.toml" <<'EOF'
[env]
PR_REVIEW_GATE = "review"
EOF
assert_eq "$(run_resolve_mode)" "review" "resolve: settings-file PR_REVIEW_GATE applies"
assert_eq "$(run_resolve_mode PR_REVIEW_GATE=approval)" "approval" "resolve: process env beats settings file"
rm -f "$TMP_ROOT/repo/kendex.settings.toml"

# The engine's one-switch gate disable wins over every reviewer-gate key —
# env and settings-file sources both; enforce (and any non-"off" value)
# leaves the reviewer keys authoritative.
assert_eq "$(run_resolve_mode REVIEW_GATE_MODE=off PR_REVIEW_GATE=approval)" "off" "resolve: REVIEW_GATE_MODE=off overrides approval"
assert_eq "$(run_resolve_mode REVIEW_GATE_MODE=off PR_REVIEW_GATE=review)" "off" "resolve: REVIEW_GATE_MODE=off overrides review"
assert_eq "$(run_resolve_mode REVIEW_GATE_MODE=enforce PR_REVIEW_GATE=review)" "review" "resolve: enforce preserves the reviewer keys"
assert_eq "$(run_resolve_mode REVIEW_GATE_MODE=bogus PR_REVIEW_GATE=review)" "review" "resolve: a non-off value never narrows (engine fails loud, not here)"
cat > "$TMP_ROOT/repo/kendex.settings.toml" <<'EOF'
[env]
REVIEW_GATE_MODE = "off"
PR_REVIEW_GATE = "review"
EOF
assert_eq "$(run_resolve_mode)" "off" "resolve: settings-file REVIEW_GATE_MODE=off applies"
rm -f "$TMP_ROOT/repo/kendex.settings.toml"

# The engine boundary (PR #1615): REVIEW_GATE_MODE resolves from process env
# and the settings files ONLY — the engine skips dotenv for this key by
# per-key exception, and a .env file is read by nothing at all, so neither
# shape may turn the waiter off while the gate stays enforcing. The
# PR_REVIEW_* keys keep full .env.local precedence.
cat > "$TMP_ROOT/repo/.env" <<'EOF'
REVIEW_GATE_MODE=off
EOF
assert_eq "$(run_resolve_mode)" "approval" "resolve: a .env REVIEW_GATE_MODE=off is read by nothing"
assert_eq "$(run_resolve_mode REVIEW_GATE_MODE=off)" "off" "resolve: parent-env off still applies beside a dotenv file"
cat > "$TMP_ROOT/repo/kendex.settings.toml" <<'EOF'
[env]
REVIEW_GATE_MODE = "off"
EOF
assert_eq "$(run_resolve_mode)" "off" "resolve: settings-file off still applies beside a dotenv file"
rm -f "$TMP_ROOT/repo/kendex.settings.toml"
mv "$TMP_ROOT/repo/.env" "$TMP_ROOT/repo/.env.local"
assert_eq "$(run_resolve_mode)" "approval" "resolve: .env.local REVIEW_GATE_MODE=off is ignored (per-key exception)"
rm -f "$TMP_ROOT/repo/.env.local"
# Control: the reviewer keys keep their .env.local precedence, so the
# exception above is the mode key's, not a dead dotenv layer.
cat > "$TMP_ROOT/repo/.env.local" <<'EOF'
PR_REVIEW_GATE=review
EOF
assert_eq "$(run_resolve_mode)" "review" "resolve: .env.local PR_REVIEW_GATE keeps full precedence (control)"
rm -f "$TMP_ROOT/repo/.env.local"

# REVIEW_GATE_MODE goes through the ENGINE's resolver (rg_setting), so its
# settings-file semantics are the engine's, not the generic loader's.
cat > "$TMP_ROOT/repo/kendex.settings.toml" <<'EOF'
[env]
REVIEW_GATE_MODE = "off"
EOF
assert_eq "$(run_resolve_mode REVIEW_GATE_SETTINGS_FILE=/dev/null)" "approval" "resolve: REVIEW_GATE_SETTINGS_FILE=/dev/null forces the default over settings off"
rm -f "$TMP_ROOT/repo/kendex.settings.toml"
cat > "$TMP_ROOT/repo/alt-settings.toml" <<'EOF'
[env]
REVIEW_GATE_MODE = "off"
EOF
assert_eq "$(run_resolve_mode REVIEW_GATE_SETTINGS_FILE=alt-settings.toml)" "off" "resolve: the REVIEW_GATE_SETTINGS_FILE override is honored"
rm -f "$TMP_ROOT/repo/alt-settings.toml"
# The engine fails loud on a duplicate assignment; the waiter propagates it
# instead of quietly picking a value the predicate would reject.
cat > "$TMP_ROOT/repo/kendex.settings.toml" <<'EOF'
[env]
REVIEW_GATE_MODE = "off"
REVIEW_GATE_MODE = "enforce"
EOF
stderr="$TMP_ROOT/dup.err"
set +e
run_resolve_mode >/dev/null 2>"$stderr"
rc=$?
set -e
assert_eq "$rc" "2" "resolve: a duplicate REVIEW_GATE_MODE assignment fails loud" "$stderr"
assert_contains "$(cat "$stderr")" "assigned more than once" "resolve: the duplicate diagnostic names the cause"
rm -f "$TMP_ROOT/repo/kendex.settings.toml"

# Without the review-gate skill, the generic-loader fallback resolves
# REVIEW_GATE_MODE from the COMMITTED kendex.settings.toml alone — matching
# the engine resolver, so installing review-gate cannot flip the mode — and
# a refused load terminates instead of resolving a mode from a partial
# read. The orch skill is a REAL COPY here, not a symlink: through a
# symlinked orch the engine lib still resolves via the link target's
# siblings and the fallback never runs.
mkdir -p "$TMP_ROOT/repo2/.agents/skills"
cp -r "$REPO_ROOT/skills/orch" "$TMP_ROOT/repo2/.agents/skills/orch"
# github supplies only the shared gh-auth shim target; a symlink is fine —
# the engine lookup resolves through orch's own physical path, not this one.
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/repo2/.agents/skills/github"
git -C "$TMP_ROOT/repo2" init -q
run_resolve_mode_fallback() {
  (cd "$TMP_ROOT/repo2" \
    && PATH="$TMP_ROOT/argbin:$PATH" \
       env "$@" .agents/skills/orch/scripts/approval-wait --resolve-mode)
}
cat > "$TMP_ROOT/repo2/kendex.settings.toml" <<'EOF'
[env]
REVIEW_GATE_MODE = "off"
EOF
assert_eq "$(run_resolve_mode_fallback)" "off" "resolve: the fallback reads the committed kendex.settings.toml"
mkdir -p "$TMP_ROOT/repo2/.kendex"
rm -f "$TMP_ROOT/repo2/kendex.settings.toml"
cat > "$TMP_ROOT/repo2/.kendex/settings.toml" <<'EOF'
[env]
REVIEW_GATE_MODE = "off"
EOF
assert_eq "$(run_resolve_mode_fallback)" "approval" "resolve: a machine-local .kendex off is IGNORED for MODE in the fallback too"
rm -f "$TMP_ROOT/repo2/.kendex/settings.toml"
cat > "$TMP_ROOT/repo2/kendex.settings.toml" <<'EOF'
[env]
REVIEW_GATE_MODE = "off"
REVIEW_GATE_MODE = "enforce"
EOF
stderr="$TMP_ROOT/fallback-dup.err"
set +e
fallback_out=$(run_resolve_mode_fallback 2>"$stderr")
rc=$?
set -e
# Exit 1, not the engine's 2: the code pins that the FALLBACK branch ran and
# refused, and the empty stdout that no mode was resolved from the partial
# read.
assert_eq "$rc" "1" "resolve: a duplicate assignment fails the fallback loud (fallback exit 1, not the engine's 2)" "$stderr"
assert_eq "$fallback_out" "" "resolve: the refused fallback load resolves no mode" "$stderr"
assert_contains "$(cat "$stderr")" "assigned more than once" "resolve: the fallback duplicate diagnostic names the cause"

echo "=== -h/--help answer in the arg parser (KEN-556) ==="

# Usage must terminate before auth or any gh call — --help was once consumed
# as the PR number (same shape as ci-wait's kendex#981). The recording stub
# proves gh was never reached, and the token pins guard the heredoc: it is
# the contract's sole home (KEN-555: tokens, never sentences).
run_help() {
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/argbin:$PATH" \
       .agents/skills/orch/scripts/approval-wait "$@")
}

stderr="$TMP_ROOT/help.err"
set +e
output=$(run_help --help 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "--help exits 0" "$stderr"
assert_contains "$output" "Usage: approval-wait" "--help prints usage"
assert_contains "$output" "Exit codes:" "--help carries the exit-code table"
assert_contains "$output" "proceeded" "--help carries the proceeded status"
assert_contains "$output" "PR_REVIEW_ON_TIMEOUT" "--help carries the on-timeout setting"
if [[ -e "$TMP_ROOT/argval-gh.calls" ]]; then
  assert_eq "$(cat "$TMP_ROOT/argval-gh.calls")" "" "--help never invokes gh"
else
  assert_eq "no-calls" "no-calls" "--help never invokes gh"
fi
rm -f "$TMP_ROOT/argval-gh.calls"

set +e
output=$(run_help -h 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "0" "-h exits 0" "$stderr"
assert_contains "$output" "Usage: approval-wait" "-h prints usage"

# An unknown flag is rejected in the parser, never absorbed into a positional
# slot (kendex#981, same shape as ci-wait case 33 and queue-wait 17b).
stderr="$TMP_ROOT/badflag.err"
set +e
output=$(run_help --bogus-flag 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "2" "unknown flag exits 2" "$stderr"
assert_contains "$(cat "$stderr")" "unknown option" "unknown-flag error names the flag"
if [[ -e "$TMP_ROOT/argval-gh.calls" ]]; then
  assert_eq "$(cat "$TMP_ROOT/argval-gh.calls")" "" "unknown flag never invokes gh"
else
  assert_eq "no-calls" "no-calls" "unknown flag never invokes gh"
fi
rm -f "$TMP_ROOT/argval-gh.calls"



# Missing arguments are the usage-error class (exit 2), never exit 1 —
# exit 1 is reserved for operational review results.
stderr="$TMP_ROOT/missing.err"
set +e
output=$(run_help 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "2" "missing PR# exits 2" "$stderr"
assert_contains "$(cat "$stderr")" "missing required <PR#>" "missing PR# names the argument"

set +e
output=$(run_help 1 --mode 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "2" "--mode without a value exits 2" "$stderr"
assert_contains "$(cat "$stderr")" "requires a value" "--mode diagnostic names the requirement"

set +e
output=$(run_help 1 --on-timeout 2>"$stderr")
rc=$?
set -e
assert_eq "$rc" "2" "--on-timeout without a value exits 2" "$stderr"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
