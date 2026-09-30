#!/usr/bin/env bash
# Tests for item-tier, the gate that assigns an item's cycle.
#
# The script runs from a copy laid out as the installed packages are:
# orch/scripts beside harness-ci/scripts. The classifier is a stub answering
# what each range row names. Location rows use harness-ci's real shared path
# rules, not that stub. The ceilings come from narrow-change.conf, so
# a boundary row follows the list rather than a second copy of its numbers.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo "item-tier: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "item-tier: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "item-tier: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"

LAYOUT="$TMP_ROOT/layout"
mkdir -p "$LAYOUT/orch/scripts/lib" "$LAYOUT/orch/references" \
  "$LAYOUT/harness-ci/scripts/lib"
cp "$ORCH_DIR/../harness-ci/scripts/lib/change-class.sh" "$LAYOUT/harness-ci/scripts/lib/"
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
chmod +x "$LAYOUT/harness-ci/scripts/change-class"
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

# The first stdout line's tier, brief and cause key, the class= token that
# follows the cause where there is one, and the exit status. The class= token
# is what separates render, trivial and micro, which all answer tier=micro,
# and review-pr.md skips the review on class=trivial alone.
run_tier() { # CLASS ARG...
  local class="$1" out rc=0
  shift
  out="$(env -i PATH="$PATH" TMPDIR="$TMP_ROOT" STUB_ARGV="$STUB_ARGV" STUB_CLASS="$class" \
    "${TIER_BIN:-$TIER}" --repo "$TMP_ROOT" "$@" 2>/dev/null)" || rc=$?
  out="$(sed -n '1s/^\(tier=[a-z]* brief=[a-z]* cause=[a-z-]*\( class=[a-z]*\)\{0,1\}\).*/\1/p' <<<"$out")"
  printf '%s' "${out:+$out }rc=$rc"
}

echo
echo "--- item-tier ---"

PR_MERGE=skills/github/scripts/commands/pr-merge.sh
# classifier|arguments|expected|row
ROWS=(
  "-|--production $MICRO_MAX|tier=micro brief=micro cause=estimate-within-micro rc=0|an estimate at the micro ceiling is micro"
  "-|--production $((MICRO_MAX + 1))|tier=small brief=small cause=estimate-within-small rc=0|an estimate one past the micro ceiling is small"
  "-|--production $SMALL_MAX|tier=small brief=small cause=estimate-within-small rc=0|an estimate at the small ceiling is small"
  "-|--production $((SMALL_MAX + 1))|tier=standard brief=start cause=estimate-past-small rc=0|an estimate one past the small ceiling is standard"
  "small|--production 1 --base b --head h|tier=small brief=small cause=classifier class=small rc=0|a micro estimate on a small branch takes the wider class"
  "micro|--production $SMALL_MAX --base b --head h|tier=small brief=small cause=estimate-within-small rc=0|a small estimate on a micro branch takes the wider class"
  "trivial|--floor small --base b --head h|tier=small brief=small cause=floor class=small rc=0|a floor holds over a narrower branch"
  "standard|--floor small --base b --head h|tier=standard brief=start cause=classifier class=standard rc=0|a branch past its floor escapes to its class"
  "exit-2|--floor small --base b --head h|tier=standard brief=start cause=classifier-failed rc=0|a classifier that cannot answer is standard"
  "-|--production 1 --path kendex.settings.toml|tier=standard brief=start cause=configuration-source rc=0|a settings Location takes the classifier's class and cause"
  "-|--production 1 --path kendex.toml|tier=standard brief=start cause=configuration-source rc=0|a manifest Location takes the classifier's class and cause"
  "-|--production 1 --path kendex-local.toml|tier=standard brief=start cause=configuration-source rc=0|a catalog manifest Location takes the classifier's class and cause"
  "-|--production 1 --path .kendex/settings.toml|tier=standard brief=start cause=configuration-source rc=0|a local settings Location takes the classifier's class and cause"
  "-|--production 1 --path src/main.rs|tier=micro brief=micro cause=estimate-within-micro rc=0|a plain source Location keeps the estimate's class"
  "-|--production 1 --path src/main.rs --path kendex.settings.toml|tier=standard brief=start cause=configuration-source rc=0|each Location is classified, not only the first"
  "-|--production 1 --path .pi/settings.json|tier=standard brief=start cause=configuration-source rc=0|a registry Location proves no render"
  "-|--production 1 --path CLAUDE.md|tier=standard brief=start cause=instruction-pointer rc=0|an instruction pointer Location proves no render"
  "-|--production 1 --path $PR_MERGE|tier=standard brief=start cause=excluded-path rc=0|a merge-gate Location is never micro whatever the estimate"
  "-|--production 1 --path skills/orch/workflows/review-pr.md|tier=micro brief=micro cause=estimate-within-micro rc=0|a Location off the list leaves the estimate's class"
  "-|--production 1 --path hooks/block-bare-cd.sh|tier=standard brief=start cause=excluded-path rc=0|a hook body Location is never micro"
  "-|--production 1 --path hooks/tests/block-bare-cd.test.sh|tier=micro brief=micro cause=estimate-within-micro rc=0|a hook suite Location leaves the estimate's class"
  "-|--production 1 --path skills/x/SKILL.md|tier=small brief=small cause=instruction-file rc=0|a SKILL.md Location is never micro"
  "-|--production 1 --path AGENTS.md|tier=small brief=small cause=instruction-file rc=0|a root AGENTS.md Location is never micro"
  "-|--production $((SMALL_MAX + 1)) --path skills/x/SKILL.md|tier=standard brief=start cause=estimate-past-small rc=0|an instruction Location leaves a wider estimate alone"
  "unmeasured|--floor micro --base b --head h|tier=standard brief=start cause=classifier-unmeasured rc=0|a standard the classifier did not measure says so"
  "nomarker|--floor micro --base b --head h|tier=standard brief=start cause=classifier-unmeasured rc=0|a class with no measured marker is standard"
  "docs|--floor micro --base b --head h|tier=standard brief=start cause=classifier-unreadable class=docs rc=0|a classifier word outside the classes is standard"
  "render|--base b --head h|tier=micro brief=micro cause=classifier class=render rc=0|a render branch counts as micro"
  "trivial|--base b --head h|tier=micro brief=micro cause=classifier class=trivial rc=0|a trivial branch is micro and names its class"
  "micro|--base b --head h|tier=micro brief=micro cause=classifier class=micro rc=0|a micro branch is micro and names its class, not trivial"
  "-|--production $SMALL_MAX --floor small|tier=small brief=small cause=estimate-within-small rc=0|of two inputs naming one class the first names the cause"
  "-||rc=2|no input is a usage error"
  "-|--production 1x|rc=2|a malformed estimate is a usage error"
  "-|--floor tiny|rc=2|an unknown floor is a usage error"
  "-|--base b|rc=2|a base without a head is a usage error"
  "-|--production 1 --head h|rc=2|a head without a base is a usage error"
)
for row in "${ROWS[@]}"; do
  IFS='|' read -r class args want name <<<"$row"
  # shellcheck disable=SC2086
  assert_eq "$(run_tier "$class" $args)" "$want" "$name"
done

# Must-fail control for the hook body row: the list's one-segment glob needs
# extglob, and a copy without it reads a hook body as off the list.
mkdir -p "$TMP_ROOT/no-extglob"
cp -R "$LAYOUT/." "$TMP_ROOT/no-extglob/"
sed '/^shopt -s extglob$/d' "$ORCH_DIR/scripts/item-tier" >"$TMP_ROOT/no-extglob/orch/scripts/item-tier"
assert_eq "$(grep -c '^shopt -s extglob$' "$ORCH_DIR/scripts/item-tier") $(grep -c '^shopt -s extglob$' "$TMP_ROOT/no-extglob/orch/scripts/item-tier" || true)" \
  "1 0" "the extglob control drops the one shopt"
TIER_BIN="$TMP_ROOT/no-extglob/orch/scripts/item-tier"
assert_eq "$(run_tier - --production 1 --path hooks/block-bare-cd.sh)" \
  "tier=micro brief=micro cause=estimate-within-micro rc=0" "an item-tier without extglob misses a hook body"
unset TIER_BIN

# Must-fail control for instruction rows: disable the class assigned by the
# shared rule. A SKILL.md Location then keeps the estimate's class.
mkdir -p "$TMP_ROOT/no-floor"
cp -R "$LAYOUT/." "$TMP_ROOT/no-floor/"
floor_line='      CHANGE_CLASS_PATH=small'
awk -v line="$floor_line" '
  $0 == line { hits++; print "      CHANGE_CLASS_PATH=\"\""; next }
  { print }
  END { exit hits == 1 ? 0 : 3 }
' "$LAYOUT/harness-ci/scripts/lib/change-class.sh" >"$TMP_ROOT/no-floor/harness-ci/scripts/lib/change-class.sh"
if cmp -s "$LAYOUT/harness-ci/scripts/lib/change-class.sh" "$TMP_ROOT/no-floor/harness-ci/scripts/lib/change-class.sh"; then
  echo "FAIL: the floor control did not change the library" >&2; exit 1
fi
TIER_BIN="$TMP_ROOT/no-floor/orch/scripts/item-tier"
assert_eq "$(run_tier - --production 1 --path skills/x/SKILL.md)" \
  "tier=micro brief=micro cause=estimate-within-micro rc=0" "an item-tier without the floor lets a SKILL.md Location run micro"
unset TIER_BIN

# Must-fail control for configuration Locations: retain the rule but disable
# its pre-render phase in a private library, restoring the old launch answer.
cp -R "$LAYOUT" "$TMP_ROOT/no-configuration"
configuration_line='  if [ "$2" = before-render ] || [ "$2" = launch ]; then'
awk -v line="$configuration_line" '
  $0 == line { hits++; print "  if false; then # " line; next }
  { print }
  END { exit hits == 1 ? 0 : 3 }
' "$LAYOUT/harness-ci/scripts/lib/change-class.sh" >"$TMP_ROOT/no-configuration/harness-ci/scripts/lib/change-class.sh"
if cmp -s "$LAYOUT/harness-ci/scripts/lib/change-class.sh" "$TMP_ROOT/no-configuration/harness-ci/scripts/lib/change-class.sh"; then
  echo "FAIL: the configuration control did not change the library" >&2; exit 1
fi
TIER_BIN="$TMP_ROOT/no-configuration/orch/scripts/item-tier"
control_out="$(run_tier - --production 1 --path kendex.settings.toml)"
assert_eq "$control_out" "tier=micro brief=micro cause=estimate-within-micro rc=0" \
  "the old launch behavior misses a settings Location"
# The regression assertion itself must reject that old answer.
if (PASS=0; FAIL=0; assert_eq "$control_out" \
  "tier=standard brief=start cause=configuration-source rc=0" "settings regression" >/dev/null; [[ "$FAIL" -eq 0 ]]); then
  fail "the settings regression accepts old behavior"
else
  pass "the settings regression turns red on old behavior"
fi
unset TIER_BIN

# A missing shared rule library refuses a narrow Location class.
cp -R "$LAYOUT" "$TMP_ROOT/no-path-rules"
rm -- "$TMP_ROOT/no-path-rules/harness-ci/scripts/lib/change-class.sh"
TIER_BIN="$TMP_ROOT/no-path-rules/orch/scripts/item-tier"
assert_eq "$(run_tier - --floor micro --path src/main.rs)" \
  "tier=standard brief=start cause=classifier-path-rules-unreadable rc=0" "missing path rules are not an unmatched Location"
unset TIER_BIN

# A ceiling list item-tier cannot use is standard, never a narrower class.
TIER_BIN="$TMP_ROOT/no-conf/orch/scripts/item-tier"
assert_eq "$(run_tier - --production 1)" \
  "tier=standard brief=start cause=narrow-change-unreadable rc=0" "no ceiling list is standard"
TIER_BIN="$TMP_ROOT/no-small-ceiling/orch/scripts/item-tier"
assert_eq "$(run_tier - --production 1)" \
  "tier=standard brief=start cause=narrow-change-ceilings-missing rc=0" "a missing ceiling is standard"
unset TIER_BIN

printf '\npass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
