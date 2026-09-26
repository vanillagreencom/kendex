#!/usr/bin/env bash
# Tests for item-tier, the gate that assigns an item's cycle.
#
# The script runs from a copy laid out as the installed packages are:
# orch/scripts beside harness-ci/scripts and review-gate/scripts. The
# classifier and the review gate's policy reader are stubs answering what each
# row names. The ceilings come from the real narrow-change.conf, so a boundary
# row follows the list rather than a second copy of its numbers.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
assert_eq() { # GOT WANT NAME
  if [[ "$1" == "$2" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$3"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$3" "$2" "$1"
  fi
}

LAYOUT="$TMP_ROOT/layout"
mkdir -p "$LAYOUT/orch/scripts/lib" "$LAYOUT/orch/references" \
  "$LAYOUT/harness-ci/scripts" "$LAYOUT/review-gate/scripts"
cp "$ORCH_DIR/scripts/item-tier" "$LAYOUT/orch/scripts/"
cp "$ORCH_DIR/scripts/lib/change-class.sh" "$LAYOUT/orch/scripts/lib/"
cp "$ORCH_DIR/references/narrow-change.conf" "$LAYOUT/orch/references/"
cat >"$LAYOUT/harness-ci/scripts/change-class" <<'SH'
#!/usr/bin/env bash
# Answers only the range the rows name, so a swapped or dropped endpoint is
# a classifier failure rather than a class. The `class:` line carries the
# measured marker the real classifier prints.
[ "$*" = "$STUB_ARGV" ] || { echo "stub: unexpected argv: $*" >&2; exit 7; }
case "$STUB_CLASS" in
  exit-2) echo "wiring-error: cause=stub" >&2; exit 2 ;;
  unmeasured)
    echo "class: class=standard measured=false cause=unresolved-endpoint endpoint=b" >&2
    printf 'change_class=standard\n' ;;
  nomarker) printf 'change_class=small\n' ;; # a change-class from before KEN-1638
  *)
    printf 'class: class=%s measured=true cause=stub\n' "$STUB_CLASS" >&2
    printf 'change_class=%s\n' "$STUB_CLASS" ;;
esac
SH
cat >"$LAYOUT/review-gate/scripts/review-policy" <<'SH'
#!/usr/bin/env bash
[ "$1" = --check-config ] || exit 9
case "$STUB_POLICY" in
  exit-2) echo "review-gate-error=policy-invalid" >&2; exit 2 ;;
  *) printf 'review-policy=%s\n' "$STUB_POLICY" ;;
esac
SH
chmod +x "$LAYOUT/harness-ci/scripts/change-class" "$LAYOUT/review-gate/scripts/review-policy"
TIER="$LAYOUT/orch/scripts/item-tier"
export STUB_ARGV="--event pull_request --base b --head h --repo $TMP_ROOT --output /dev/null"

# Two layouts whose ceiling list item-tier cannot use: one without the file,
# one without the small ceiling line.
for variant in no-conf no-small-ceiling; do
  cp -R "$LAYOUT" "$TMP_ROOT/$variant"
done
rm -- "${TMP_ROOT:?}/no-conf/orch/references/narrow-change.conf"
grep -v '^small_max_production=' "$ORCH_DIR/references/narrow-change.conf" \
  >"$TMP_ROOT/no-small-ceiling/orch/references/narrow-change.conf"

conf_value() { sed -n "s/^$1=//p" "$ORCH_DIR/references/narrow-change.conf"; }
MICRO_MAX="$(conf_value micro_max_production)"
SMALL_MAX="$(conf_value small_max_production)"
[[ "$MICRO_MAX" =~ ^[0-9]+$ && "$SMALL_MAX" =~ ^[0-9]+$ ]] || {
  echo "FAIL: the ceiling reader found no ceilings in narrow-change.conf" >&2
  exit 1
}

# The first stdout line's tier, brief and cause key, and the exit status.
run_tier() { # POLICY CLASS ARG...
  local policy="$1" class="$2" out rc=0
  shift 2
  out="$(STUB_POLICY="$policy" STUB_CLASS="$class" "${TIER_BIN:-$TIER}" --repo "$TMP_ROOT" "$@" 2>/dev/null)" || rc=$?
  out="$(sed -n '1s/^\(tier=[a-z]* brief=[a-z]* cause=[a-z-]*\).*/\1/p' <<<"$out")"
  printf '%s' "${out:+$out }rc=$rc"
}

echo
echo "--- item-tier ---"

PR_MERGE=skills/github/scripts/commands/pr-merge.sh
# policy|classifier|arguments|expected|row
ROWS=(
  "active|-|--production $MICRO_MAX|tier=micro brief=micro cause=estimate-within-micro rc=0|an estimate at the micro ceiling is micro"
  "active|-|--production $((MICRO_MAX + 1))|tier=small brief=small cause=estimate-within-small rc=0|an estimate one past the micro ceiling is small"
  "active|-|--production $SMALL_MAX|tier=small brief=small cause=estimate-within-small rc=0|an estimate at the small ceiling is small"
  "active|-|--production $((SMALL_MAX + 1))|tier=standard brief=start cause=estimate-past-small rc=0|an estimate one past the small ceiling is standard"
  "active|small|--production 1 --base b --head h|tier=small brief=small cause=classifier rc=0|a micro estimate on a small branch takes the wider class"
  "active|micro|--production $SMALL_MAX --base b --head h|tier=small brief=small cause=estimate-within-small rc=0|a small estimate on a micro branch takes the wider class"
  "active|trivial|--floor small --base b --head h|tier=small brief=small cause=floor rc=0|a floor holds over a narrower branch"
  "active|standard|--floor small --base b --head h|tier=standard brief=start cause=classifier rc=0|a branch past its floor escapes to its class"
  "active|exit-2|--floor small --base b --head h|tier=standard brief=start cause=classifier-failed rc=0|a classifier that cannot answer is standard"
  "active|-|--production 1 --path $PR_MERGE|tier=standard brief=start cause=excluded-path rc=0|a merge-gate Location is never micro whatever the estimate"
  "active|-|--production 1 --path skills/orch/workflows/review-pr.md|tier=micro brief=micro cause=estimate-within-micro rc=0|a Location off the list leaves the estimate's class"
  "active|unmeasured|--floor micro --base b --head h|tier=standard brief=start cause=classifier-unmeasured rc=0|a standard the classifier did not measure says so"
  "active|nomarker|--floor micro --base b --head h|tier=standard brief=start cause=classifier-unmeasured rc=0|a class with no measured marker is standard"
  "active|docs|--floor micro --base b --head h|tier=standard brief=start cause=classifier-unreadable rc=0|a classifier word outside the classes is standard"
  "active|render|--base b --head h|tier=micro brief=micro cause=classifier rc=0|a render branch counts as micro"
  "active|-|--production $SMALL_MAX --floor small|tier=small brief=small cause=estimate-within-small rc=0|of two inputs naming one class the first names the cause"
  "inactive|-|--production 1|tier=small brief=small cause=review-policy-inactive rc=0|an inactive class policy refuses micro and names why"
  "inactive|-|--production $((SMALL_MAX + 1))|tier=standard brief=start cause=estimate-past-small rc=0|an inactive class policy leaves a wider tier alone"
  "exit-2|-|--production 1|tier=small brief=small cause=review-policy-unreadable rc=0|a class policy read that fails refuses micro"
  "unknown|-|--production 1|tier=small brief=small cause=review-policy-unreadable rc=0|a class policy answer outside the two refuses micro"
  "active|-||rc=2|no input is a usage error"
  "active|-|--production 1x|rc=2|a malformed estimate is a usage error"
  "active|-|--floor tiny|rc=2|an unknown floor is a usage error"
  "active|-|--base b|rc=2|a base without a head is a usage error"
  "active|-|--production 1 --head h|rc=2|a head without a base is a usage error"
)
for row in "${ROWS[@]}"; do
  IFS='|' read -r policy class args want name <<<"$row"
  # shellcheck disable=SC2086
  assert_eq "$(run_tier "$policy" "$class" $args)" "$want" "$name"
done

# A ceiling list item-tier cannot use is standard, never a narrower class.
TIER_BIN="$TMP_ROOT/no-conf/orch/scripts/item-tier"
assert_eq "$(run_tier active - --production 1)" \
  "tier=standard brief=start cause=narrow-change-unreadable rc=0" "no ceiling list is standard"
TIER_BIN="$TMP_ROOT/no-small-ceiling/orch/scripts/item-tier"
assert_eq "$(run_tier active - --production 1)" \
  "tier=standard brief=start cause=narrow-change-ceilings-missing rc=0" "a missing ceiling is standard"
unset TIER_BIN

# The review gate absent is the policy unread.
mv "$LAYOUT/review-gate" "$LAYOUT/review-gate.off"
assert_eq "$(run_tier active - --production 1)" \
  "tier=small brief=small cause=review-policy-absent rc=0" "no review gate refuses micro"
mv "$LAYOUT/review-gate.off" "$LAYOUT/review-gate"

printf '\npass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
