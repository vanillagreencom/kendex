#!/usr/bin/env bash
# The settings loaders are vendored, not shared: each skill package installs
# standalone, so a copy that sourced another skill's path would break any
# repo that installed only that one skill. Sameness is therefore a pin, not
# a consequence — this suite is what makes an edit to one copy red.
#
# Two families:
#   * kendex-env.sh — six skills carry it, byte-identical, sources and
#     rendered .agents copies alike.
#   * the [env] table reader in lib/settings.sh — growth-guards, review-gate
#     and size-ratchet carry one awk function apiece, identical once the
#     gg_/rg_/sr_ prefix is normalized away.
#
# Behavioral changes belong in skills/orch/scripts/lib/kendex-env.sh and
# skills/review-gate/scripts/lib/settings.sh, then re-vendored to the rest.
# Precedence behavior is proven once, by
# skills/orch/tests/kendex-env-precedence.sh; nothing here re-runs it.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

ENV_SKILLS="decider github linear orch second-opinion worktree"
TABLE_SKILLS="growth-guards:gg review-gate:rg size-ratchet:sr"

# The [env] reader of one lib/settings.sh, with its prefix normalized so the
# three copies are comparable as text.
env_table_body() { # FILE PREFIX
  awk -v p="$2" '$0 ~ "^" p "_env_table\\(\\)" { f = 1 } f { print } f && /^}$/ { exit }' "$1" \
    | sed "s/${2}_/PFX_/g"
}

# Both pins, against an arbitrary tree root. Diagnostics on stdout, one
# nonzero exit for any divergence — the controls below run this against a
# deliberately edited copy of the tree and require that exit. A missing file
# or an absent function is a divergence too: a check with nothing to compare
# would otherwise report the same green as one that compared everything.
check_tree() { # ROOT
  local root="$1" rc=0 parent skill prefix path first="" first_path="" body
  for parent in skills .agents/skills; do
    for skill in $ENV_SKILLS; do
      path="$root/$parent/$skill/scripts/lib/kendex-env.sh"
      if [ ! -f "$path" ]; then
        echo "missing vendored copy: $path"
        rc=1
        continue
      fi
      if [ -z "$first" ]; then
        first="$path"
        continue
      fi
      if ! cmp -s "$first" "$path"; then
        echo "$path is not byte-identical to $first"
        rc=1
      fi
    done
  done
  first=""
  for parent in skills .agents/skills; do
    for skill in $TABLE_SKILLS; do
      prefix="${skill##*:}"
      path="$root/$parent/${skill%%:*}/scripts/lib/settings.sh"
      if [ ! -f "$path" ]; then
        echo "missing vendored copy: $path"
        rc=1
        continue
      fi
      body="$(env_table_body "$path" "$prefix")"
      if [ -z "$body" ]; then
        echo "no ${prefix}_env_table found in $path"
        rc=1
        continue
      fi
      if [ -z "$first_path" ]; then
        first="$body"
        first_path="$path"
        continue
      fi
      if [ "$body" != "$first" ]; then
        echo "the [env] reader in $path differs from $first_path by more than its prefix"
        rc=1
      fi
    done
  done
  return "$rc"
}

echo "=== the vendored copies are one text ==="
if check_tree "$REPO_ROOT"; then
  ok "every kendex-env.sh copy and every [env] reader matches its siblings"
else
  bad "the vendored copies have diverged (see above)"
fi

# A tree holding only the files check_tree reads, so a control can edit one
# copy without touching the repository.
control="$TMP/control"
for parent in skills .agents/skills; do
  for skill in $ENV_SKILLS; do
    mkdir -p "$control/$parent/$skill/scripts/lib"
    cp "$REPO_ROOT/$parent/$skill/scripts/lib/kendex-env.sh" "$control/$parent/$skill/scripts/lib/"
  done
  for skill in $TABLE_SKILLS; do
    mkdir -p "$control/$parent/${skill%%:*}/scripts/lib"
    cp "$REPO_ROOT/$parent/${skill%%:*}/scripts/lib/settings.sh" "$control/$parent/${skill%%:*}/scripts/lib/"
  done
done
check_tree "$control" >/dev/null 2>&1 \
  && ok "the control tree starts clean" \
  || bad "the control tree is already divergent — later controls prove nothing"

echo "=== an edit to one copy is caught (control) ==="
edited="$control/skills/worktree/scripts/lib/kendex-env.sh"
printf '\n# an edit no other copy carries\n' >> "$edited"
if check_tree "$control" >/dev/null 2>&1; then
  bad "an edited kendex-env.sh copy passed the equality pin"
else
  ok "an edited kendex-env.sh copy fails the equality pin"
fi
cp "$REPO_ROOT/skills/worktree/scripts/lib/kendex-env.sh" "$edited"

# The prefix normalization must not hide a real change: this edit is inside
# the awk body, where no prefix appears.
edited="$control/skills/size-ratchet/scripts/lib/settings.sh"
sed 's/in_env = (header == "\[env\]")/in_env = (header == "[ENV]")/' "$edited" > "$TMP/edited.sh"
cmp -s "$edited" "$TMP/edited.sh" && bad "the [env] reader edit changed nothing — the control is inert"
cp "$TMP/edited.sh" "$edited"
if check_tree "$control" >/dev/null 2>&1; then
  bad "an edited [env] reader passed the prefix-normalized pin"
else
  ok "an edited [env] reader fails the prefix-normalized pin"
fi

# The two arms that keep a check with nothing to compare from passing.
cp "$REPO_ROOT/skills/size-ratchet/scripts/lib/settings.sh" "$edited"
sed 's/^sr_env_table()/sr_table()/' "$edited" > "$TMP/renamed.sh"
cmp -s "$edited" "$TMP/renamed.sh" && bad "the rename control changed nothing — it is inert"
cp "$TMP/renamed.sh" "$edited"
if check_tree "$control" >/dev/null 2>&1; then
  bad "a renamed [env] reader passed as nothing to compare"
else
  ok "a renamed [env] reader fails instead of passing vacuously"
fi
cp "$REPO_ROOT/skills/size-ratchet/scripts/lib/settings.sh" "$edited"

rm -f "$control/skills/decider/scripts/lib/kendex-env.sh"
if check_tree "$control" >/dev/null 2>&1; then
  bad "a missing vendored copy passed as nothing to compare"
else
  ok "a missing vendored copy fails instead of passing vacuously"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
