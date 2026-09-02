#!/usr/bin/env bash
# The predicate is env-driven and takes no positional arguments. An unknown
# argument is a configuration error: exit 2 with NO verdict line, before any
# settings or evidence read — a misspelled wrapper flag must never fall
# through to a normal gate evaluation.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREDICATE="$(cd "$TEST_DIR/.." && pwd)/scripts/review-predicate.sh"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

echo "=== review-predicate rejects unknown arguments without a verdict ==="

# Validation is by argument count, not position: an explicitly empty
# argument, an empty argument smuggling a flag behind it, and any list of
# two or more arguments — help forms included — all reject.
reject_case() {
  local name="$1"; shift
  local out code err
  set +e
  out=$("$PREDICATE" "$@" 2>"$TEST_DIR/.stderr")
  code=$?
  err=$(cat "$TEST_DIR/.stderr"); rm -f "$TEST_DIR/.stderr"
  set -e
  [[ "$code" -eq 2 ]] && ok "$name exits 2" || bad "$name exits 2 (got $code)"
  grep -qF "unknown argument" <<<"$err" && ok "$name names the rejection" || bad "$name names the rejection"
  if grep -q "^verdict=" <<<"$out"; then
    bad "$name emits no verdict line"
  else
    ok "$name emits no verdict line"
  fi
}

reject_case "'--wibble'" --wibble
reject_case "'-x'" -x
reject_case "'extra'" extra
reject_case "'--help=1'" "--help=1"
reject_case "explicitly empty argument" ""
reject_case "empty argument then flag" "" --wibble
reject_case "--help with a trailing argument" --help extra
reject_case "repeated -h" -h -h
reject_case "--check-config with a trailing argument" --check-config extra
reject_case "repeated --check-config" --check-config --check-config

out=$("$PREDICATE" --help)
grep -qF "no positional arguments" <<<"$out" && ok "--help states the no-positionals contract" || bad "--help states the no-positionals contract"
grep -qF -- "--check-config" <<<"$out" && ok "--help documents the config-only flag" || bad "--help documents the config-only flag"

echo "=== --check-config validates settings without a PR or an evidence read ==="

# GH_REPO / PR_NUMBER / HEAD_SHA deliberately unset: the flag's whole point
# is answering before the predicate needs a PR. A required-env error here
# would mean the stop moved below the env check and the flag became
# unusable from a repo checkout.
cfg_rc=0
cfg_err=""
cfg_out=$(env -u GH_REPO -u PR_NUMBER -u HEAD_SHA -u REVIEW_GATE_MODE \
  REVIEW_GATE_SETTINGS_FILE=/dev/null "$PREDICATE" --check-config 2>"$TEST_DIR/.stderr") || cfg_rc=$?
cfg_err=$(cat "$TEST_DIR/.stderr"); rm -f "$TEST_DIR/.stderr"
[[ "$cfg_rc" -eq 0 ]] && ok "--check-config exits 0 on a legal configuration with no PR env" ||
  bad "--check-config exits 0 on a legal configuration with no PR env (got $cfg_rc: $cfg_err)"
grep -q "^verdict=" <<<"$cfg_out" && bad "--check-config emits no verdict line" ||
  ok "--check-config emits no verdict line"

# The failing direction, one per rule class: a value the predicate refuses
# must refuse HERE too, or the flag would report a clean configuration that
# closes the gate on the next real run.
config_reject() { # NAME KEY VALUE
  local rc=0 err
  env -u GH_REPO -u PR_NUMBER -u HEAD_SHA REVIEW_GATE_SETTINGS_FILE=/dev/null \
    "$2=$3" "$PREDICATE" --check-config >/dev/null 2>"$TEST_DIR/.stderr" || rc=$?
  err=$(cat "$TEST_DIR/.stderr"); rm -f "$TEST_DIR/.stderr"
  [[ "$rc" -eq 2 ]] && ok "--check-config refuses $1" || bad "--check-config refuses $1 (got $rc)"
  grep -qF "$2" <<<"$err" && ok "--check-config names $2 in its error" || bad "--check-config names $2 in its error"
}

config_reject "an unknown mode" REVIEW_GATE_MODE bogus
config_reject "an out-of-range sha floor" REVIEW_GATE_SHA_PREFIX_FLOOR 2
config_reject "a zero retry budget" REVIEW_GATE_API_ATTEMPTS 0
config_reject "an unknown carry class" REVIEW_GATE_CARRY_FORWARD prose
config_reject "an empty gate context" REVIEW_GATE_CONTEXT ""
# The grammar rule this flag used to exit before: a malformed pair reported a
# legal configuration and then failed the next live evaluation.
config_reject "a malformed comment-reviewer pair" REVIEW_GATE_COMMENT_REVIEWERS "missing-colon"
config_reject "a comment-reviewer pair with an empty login" REVIEW_GATE_COMMENT_REVIEWERS ":pattern"
# Exclusion-pattern spelling is judged HERE and nowhere else: the matcher
# lives in this file, so a second grammar elsewhere can only drift from it.
config_reject "an exclusion anchored with a leading '/'" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "/AGENTS.md"
config_reject "a parent-relative exclusion" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "../future/*"
config_reject "a dot-relative exclusion" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "./future/*"
# The rule is REACHABILITY, not a list of anchors: a '.' component is
# unreachable wherever it sits, not only at the front.
config_reject "an embedded dot component" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "docs/./guide.md"
config_reject "an exclusion with an empty path component" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "docs//guide.md"
config_reject "an exclusion ending in '/'" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "docs/"
config_reject "an unreachable PROPHYLACTIC declaration" REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC "../future/*"

# The grammar is CLOSED — path characters plus '*' — so each metacharacter
# `case` also offers is refused as a spelling rather than analysed. '[.]' and
# '\.' respell the '.' component the rules above reject, and refusing the
# spelling is what leaves no equivalence to find.
config_reject "a bracket class" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "[.]/future/*"
config_reject "a backslash escape" REVIEW_GATE_CARRY_FORWARD_EXCLUDE 'docs/\.md'
config_reject "a '?' wildcard" REVIEW_GATE_CARRY_FORWARD_EXCLUDE "docs/?.md"

# ...and the grammar itself is accepted, or the refusals above would just be
# a broken checker.
for spelling in '*AGENTS.md' 'docs/*' '.github/*' 'docs/**/notes.md'; do
  rc=0
  env -u GH_REPO -u PR_NUMBER -u HEAD_SHA REVIEW_GATE_SETTINGS_FILE=/dev/null \
    REVIEW_GATE_CARRY_FORWARD_EXCLUDE="$spelling" "$PREDICATE" --check-config >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] && ok "--check-config accepts the grammar's own spelling '$spelling'" ||
    bad "--check-config accepts the grammar's own spelling '$spelling' (got $rc)"
done

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
