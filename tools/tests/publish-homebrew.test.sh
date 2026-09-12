#!/usr/bin/env bash
# tools/publish-homebrew: what it refuses, which recipe it defers, what a dry
# run leaves alone, and what a push lands. Every run is over a world built
# here: a tree holding the tool and two recipes, and a bare "tap" repository
# on a local path that TAP_REMOTE points the tool at, so no run reaches the
# network. The fixture recipes pin the placeholder the way the real ones do
# today; `fill` replaces a recipe's placeholder with a real digest.
#
# A run renders as `rc=<n> keys=<k=v,...>`: the exit status and every
# `publish-homebrew: <key>=<value>` line, stdout and stderr together, in
# order and joined by `,`. The English under a keyed line is not pinned.
#
# The rows table is `label|fill|argv|token|rc|keys`:
#   fill    which recipes get a real digest first: `none`, `cli`, `both`
#   argv    the arguments as written, `-` for none
#   token   `yes` PUBLISH_TOKEN set, `no` unset
#   keys    the keyed lines, `-` for none
#
# The last block is the executable must-fail control the placeholder rows
# rest on: a copy of the tool with the guard cut out is run over the
# placeholder world and must report the recipes as changed, which is the
# answer the deferral rows would go red on.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../.." && pwd)"
TMP="$(mktemp -d)" || { echo "publish-homebrew.test: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

TAP=vanillagreencom/homebrew-kendex
PLACEHOLDER='0000000000000000000000000000000000000000000000000000000000000000'
REAL='1111111111111111111111111111111111111111111111111111111111111111'

recipe() { # NAME DIGEST — a recipe body pinning one download to DIGEST
  printf '# %s\nurl "https://example.invalid/v1.2.3/%s"\nsha256 "%s"\n' "$1" "$1" "$2"
}

# world NAME — a fresh world at $TMP/w-NAME: the tree and a tap whose main
# already holds the two recipes at an older digest, so a push has a diff.
world() {
  local dir="$TMP/w-$1" tree="$TMP/w-$1/tree" seed="$TMP/w-$1/seed"
  rm -rf -- "$dir"
  mkdir -p "$tree/tools" "$tree/packaging/homebrew" "$seed/Formula" "$seed/Casks"
  cp -- "$REPO/tools/publish-homebrew" "$tree/tools/"
  git -C "$tree" init --quiet
  recipe kendex-cli.rb "$PLACEHOLDER" >"$tree/packaging/homebrew/kendex-cli.rb"
  recipe kendex-cask.rb "$PLACEHOLDER" >"$tree/packaging/homebrew/kendex-cask.rb"
  git -C "$tree" add --all
  git -C "$tree" -c user.name=world -c user.email=world@example.invalid commit --quiet -m 'tree'
  recipe kendex-cli.rb "$REAL" | sed 's/v1.2.3/v1.2.2/' >"$seed/Formula/kendex-cli.rb"
  recipe kendex-cask.rb "$REAL" | sed 's/v1.2.3/v1.2.2/' >"$seed/Casks/kendex.rb"
  git -C "$seed" init --quiet -b main
  git -C "$seed" add --all
  git -C "$seed" -c user.name=tap -c user.email=tap@example.invalid commit --quiet -m 'tap'
  git clone --quiet --bare -- "$seed" "$dir/tap.git"
  rm -rf -- "$seed"
  printf '%s\n' "$dir"
}

fill() { # WORLD-DIR NAME... — those recipes pin a real digest, committed
  local dir="$1" name
  shift
  for name in "$@"; do
    sed -i.bak "s/$PLACEHOLDER/$REAL/" "$dir/tree/packaging/homebrew/$name" && rm -- "$dir/tree/packaging/homebrew/$name.bak"
    grep -q "$PLACEHOLDER" "$dir/tree/packaging/homebrew/$name" && { echo "publish-homebrew.test: fill left a placeholder in $name" >&2; exit 1; }
  done
  git -C "$dir/tree" -c user.name=world -c user.email=world@example.invalid commit --quiet -am 'fill'
}

# run WORLD-DIR TOKEN ARGV... — sets RC, OUT, KEYS
run() {
  local dir="$1" token="$2" line
  shift 2
  RC=0
  if [ "$token" = yes ]; then
    OUT="$(cd "$dir/tree" && TAP_REMOTE="$dir/tap.git" PUBLISH_TOKEN=test-token tools/publish-homebrew "$@" 2>&1)" || RC=$?
  else
    OUT="$(cd "$dir/tree" && TAP_REMOTE="$dir/tap.git" env -u PUBLISH_TOKEN tools/publish-homebrew "$@" 2>&1)" || RC=$?
  fi
  KEYS=""
  while IFS= read -r line; do
    case "$line" in
      'publish-homebrew: '*) KEYS="$KEYS,${line#publish-homebrew: }" ;;
    esac
  done <<EOF_OUT
$OUT
EOF_OUT
  KEYS="${KEYS#,}"
  [ -n "$KEYS" ] || KEYS="-"
}

tap_head() { git --git-dir="$1/tap.git" rev-parse main; }

rows="
both placeholders, dry run|none|--dry-run|no|0|deferred=packaging/homebrew/kendex-cli.rb,deferred=packaging/homebrew/kendex-cask.rb,nothing=$TAP
both placeholders, real run|none|-|yes|0|deferred=packaging/homebrew/kendex-cli.rb,deferred=packaging/homebrew/kendex-cask.rb,nothing=$TAP
formula filled, dry run|cli|--dry-run|no|0|deferred=packaging/homebrew/kendex-cask.rb,changed=$TAP,dry-run=$TAP
both filled, dry run|both|--dry-run|no|0|changed=$TAP,dry-run=$TAP
no token, real run|both|-|no|1|token=missing
unknown option|both|--nope|yes|2|option=--nope
"
while IFS='|' read -r label fills argv token rc keys; do
  [ -n "$label" ] || continue
  dir="$(world row)"
  case "$fills" in
    none) ;;
    cli) fill "$dir" kendex-cli.rb ;;
    both) fill "$dir" kendex-cli.rb kendex-cask.rb ;;
  esac
  before="$(tap_head "$dir")"
  if [ "$argv" = "-" ]; then run "$dir" "$token"; else
    # shellcheck disable=SC2086
    run "$dir" "$token" $argv
  fi
  after="$(tap_head "$dir")"
  if [ "$RC" = "$rc" ] && [ "$KEYS" = "$keys" ]; then
    ok "$label: rc=$rc keys=$keys"
  else
    bad "$label: want rc=$rc keys=$keys" "got rc=$RC keys=$KEYS
$OUT"
  fi
  if [ "$before" = "$after" ]; then
    ok "$label: the tap was not written"
  else
    bad "$label: the tap was written" "$before -> $after"
  fi
done <<EOF_ROWS
$rows
EOF_ROWS

# A dry run prints the whole diff, so a reader can review what a push would carry.
dir="$(world diff)"
fill "$dir" kendex-cli.rb
run "$dir" no --dry-run
case "$OUT" in
  *'-url "https://example.invalid/v1.2.2/kendex-cli.rb"'*'+url "https://example.invalid/v1.2.3/kendex-cli.rb"'*) ok "dry run prints the diff" ;;
  *) bad "dry run prints the diff" "$OUT" ;;
esac

# A push lands the tree's recipes on the tap's main under the expected paths.
dir="$(world push)"
fill "$dir" kendex-cli.rb kendex-cask.rb
before="$(tap_head "$dir")"
run "$dir" yes
after="$(tap_head "$dir")"
if [ "$RC" = 0 ] && [ "$KEYS" = "changed=$TAP,pushed=$TAP" ]; then
  ok "push: rc=0 keys=$KEYS"
else
  bad "push" "rc=$RC keys=$KEYS
$OUT"
fi
if [ "$before" != "$after" ] &&
  [ "$(git --git-dir="$dir/tap.git" show main:Formula/kendex-cli.rb)" = "$(cat "$dir/tree/packaging/homebrew/kendex-cli.rb")" ] &&
  [ "$(git --git-dir="$dir/tap.git" show main:Casks/kendex.rb)" = "$(cat "$dir/tree/packaging/homebrew/kendex-cask.rb")" ]; then
  ok "push: the tap's main holds Formula/kendex-cli.rb and Casks/kendex.rb from this tree"
else
  bad "push: the tap's main holds this tree's recipes" "$before -> $after"
fi
subject="$(git --git-dir="$dir/tap.git" log -1 --format=%s main)"
revision="$(git -C "$dir/tree" rev-parse --short=7 HEAD)"
if [ "$subject" = "sync from vanillagreencom/kendex $revision" ]; then
  ok "push: the commit names this tree's revision"
else
  bad "push: the commit names this tree's revision" "$subject"
fi
if ! git --git-dir="$dir/tap.git" config --get-regexp 'http\..*extraheader' >/dev/null 2>&1; then
  ok "push: no token in the tap's configuration"
else
  bad "push: the token reached the tap's configuration"
fi

# A second run after the push finds nothing to do.
run "$dir" yes
if [ "$RC" = 0 ] && [ "$KEYS" = "unchanged=$TAP" ]; then
  ok "push again: unchanged"
else
  bad "push again: unchanged" "rc=$RC keys=$KEYS"
fi

# A tap that cannot be cloned fails, after the deferral decision and before any write.
dir="$(world clone)"
fill "$dir" kendex-cli.rb kendex-cask.rb
rm -rf -- "$dir/tap.git"
run "$dir" yes --dry-run
if [ "$RC" = 1 ] && [ "$KEYS" = "clone=$TAP" ]; then
  ok "clone failure: rc=1 keys=$KEYS"
else
  bad "clone failure" "rc=$RC keys=$KEYS
$OUT"
fi

# The must-fail control for the placeholder rows: the same world, run by a
# copy of the tool with the guard cut out between its markers, must report
# the recipes as changed. That is the answer the deferral rows would go red
# on, which is what makes them rows about the guard and not about the world.
dir="$(world control)"
stripped="$dir/tree/tools/publish-homebrew"
if grep -q '# placeholder guard: begin' "$stripped" && grep -q '# placeholder guard: end' "$stripped"; then
  ok "control: the guard's markers are present"
else
  bad "control: the guard's markers are missing, so the control cannot cut the guard out"
fi
sed -i.bak '/# placeholder guard: begin/,/# placeholder guard: end/d' "$stripped" && rm -- "$stripped.bak"
if grep -q 'PLACEHOLDER\|placeholder"' "$stripped" && grep -q 'grep -q -- "\$placeholder"' "$stripped"; then
  bad "control: the guard survived the cut"
fi
run "$dir" no --dry-run
if [ "$RC" = 0 ] && [ "$KEYS" = "changed=$TAP,dry-run=$TAP" ]; then
  ok "control: without the guard the placeholder recipes are reported as changed (the deferral rows would go red)"
else
  bad "control: without the guard, want keys=changed=$TAP,dry-run=$TAP" "got rc=$RC keys=$KEYS
$OUT"
fi

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
