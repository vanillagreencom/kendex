#!/usr/bin/env bash
# lane-marker: the one writer of a lane's launch record, both halves of it —
# the marker under the common git directory that lane-mail-check reads to know
# a session is a launched lane, and the lane's own tmp/lane-mail/<ITEM>, which
# that hook resolves the item by.
#
# Every case builds a worktree under TMP_ROOT, runs the real script against it
# and asserts its exit status, the keyed first line of stderr, and what stands
# on disk after. The containment rows matter most: this script is where the two
# launchers' hand-rolled copies of that rule were folded, and lane-mail is the
# owner it now agrees with — from tmp/lane-mail down, with tmp itself left
# alone because a worktree setup may link it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
LANE_MARKER="$SCRIPTS_DIR/lane-marker"
TMP_ROOT="$(cd -- "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

PASS=0
FAIL=0
assert_eq() { # GOT WANT LABEL
  if [[ "$1" == "$2" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$3" "$2" "$1"
  fi
}

# A worktree to mark. LINKED_TMP=1 makes its tmp a symlink to a directory
# outside it, the shape skills/worktree's WORKTREE_SYMLINKS produces.
WT=""
new_tree() { # NAME [LINKED_TMP]
  WT="$TMP_ROOT/$1"
  mkdir -p "$WT"
  git -C "$WT" init -q
  git -C "$WT" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
  if [[ -n "${2:-}" ]]; then
    mkdir -p "$TMP_ROOT/$1-scratch"
    ln -s -f -n "$TMP_ROOT/$1-scratch" "$WT/tmp"
  fi
}

RC=0
ERR=""
# One run, and what it left: `rc=<status> first=<keyed line or -> marker=<root
# |other|none> box=<made|none>`.
mark() { # ITEM [SCRIPT]
  local item="$1" lower out first=- marker=none box=none
  lower="$(printf '%s' "$item" | tr 'A-Z' 'a-z')"
  RC=0
  out="$("${2:-$LANE_MARKER}" "$WT" "$item" 2>&1)" || RC=$?
  ERR="$out"
  [[ -z "$out" ]] || first="${out%%$'\n'*}"
  if [[ -f "$WT/.git/lane-mail/$lower" ]]; then
    marker=other
    [[ "$(cat "$WT/.git/lane-mail/$lower")" != "$(git -C "$WT" rev-parse --show-toplevel)" ]] || marker=root
  fi
  # A plain directory, never a link a row planted: -d alone follows one.
  { [[ -L "$WT/tmp/lane-mail/$item" ]] || [[ ! -d "$WT/tmp/lane-mail/$item" ]]; } || box=made
  printf 'rc=%s first=%s marker=%s box=%s' "$RC" "$first" "$marker" "$box"
}

echo "=== lane-marker ==="

new_tree plain
assert_eq "$(mark KEN-1)" "rc=0 first=- marker=root box=made" \
  "a launch writes the marker with the lane's root and opens the lane's own mailbox"
assert_eq "$(mark KEN-1)" "rc=0 first=- marker=root box=made" \
  "a second launch of the same item leaves both standing"

# The shape the two hand-rolled copies refused and lane-mail has always
# allowed: a worktree whose tmp is a link to scratch outside the tree.
new_tree linked-tmp 1
assert_eq "$(mark KEN-2)" "rc=0 first=- marker=root box=made" \
  "a worktree whose tmp is a symlink is marked and gets its mailbox"

# Containment, from tmp/lane-mail down. Each row plants one component and
# asserts nothing was written through it.
# The planted links point at a directory that exists, so a run without the
# containment rule really does write through them; the control at the end
# shows that it does.
AWAY="$TMP_ROOT/away"
mkdir -p "$AWAY"
new_tree link-lane-mail
mkdir -p "$WT/tmp"
ln -s -f -n "$AWAY" "$WT/tmp/lane-mail"
assert_eq "$(mark KEN-3) through=$([[ -e "$AWAY/KEN-3" ]] && echo written || echo untouched)" \
  "rc=2 first=lane-marker: unsafe=$WT/tmp/lane-mail marker=none box=none through=untouched" \
  "a symlink at tmp/lane-mail is refused and nothing is written through it"

new_tree link-box
mkdir -p "$WT/tmp/lane-mail"
ln -s -f -n "$AWAY" "$WT/tmp/lane-mail/KEN-4"
assert_eq "$(mark KEN-4) through=$([[ -e "$AWAY/to-lane.jsonl" ]] && echo written || echo untouched)" \
  "rc=2 first=lane-marker: unsafe=$WT/tmp/lane-mail/KEN-4 marker=none box=none through=untouched" \
  "a symlink at the lane's own mailbox is refused"

new_tree file-lane-mail
mkdir -p "$WT/tmp"
: > "$WT/tmp/lane-mail"
assert_eq "$(mark KEN-5)" "rc=2 first=lane-marker: unsafe=$WT/tmp/lane-mail marker=none box=none" \
  "a plain file where the mailbox directory belongs is refused"

new_tree link-marker
mkdir -p "$WT/.git/lane-mail"
ln -s -f -n "$TMP_ROOT/marker-target" "$WT/.git/lane-mail/ken-6"
assert_eq "$(mark KEN-6) target=$([[ -e "$TMP_ROOT/marker-target" ]] && echo written || echo untouched)" \
  "rc=2 first=lane-marker: unsafe=$WT/.git/lane-mail/ken-6 marker=none box=none target=untouched" \
  "a symlink at the marker path is refused and its target is never written"

# The item reaches two directory names, so it is judged in the same alphabet
# lane-mail-check reads one in, before it reaches a path.
new_tree bad-item
for bad in ../escape 'two words' '' .; do
  assert_eq "$(mark "$bad" | sed 's/ marker=.*//')" "rc=2 first=lane-marker: item=invalid" \
    "the item [$bad] is refused rather than composed into a path"
done

# A directory that is no repository has no root and no common git directory.
new_tree norepo
rm -rf -- "${WT:?}/.git"
assert_eq "$(mark KEN-7 | sed 's/ marker=.*//')" \
  "rc=2 first=lane-marker: git=rev-parse --git-common-dir" \
  "a worktree git cannot report is refused, never marked"

new_tree args
assert_eq "$("$LANE_MARKER" "$WT" 2>&1 | head -1)" "lane-marker: args=1" \
  "a call that names no item is refused"

# The orch script table states that every script but two answers --help, so
# this one does rather than refusing it as a one-argument call. It prints the
# usage, the containment rule and the exit statuses, which live nowhere else.
HELP_RC=0
HELP_OUT="$("$LANE_MARKER" --help 2>&1)" || HELP_RC=$?
assert_eq "rc=$HELP_RC usage=$(printf '%s' "$HELP_OUT" | grep -c '^Usage: lane-marker WORKTREE ITEM$') contain=$(printf '%s' "$HELP_OUT" | grep -c '^Containment:') status=$(printf '%s' "$HELP_OUT" | grep -c '^Exit status:$')" \
  "rc=0 usage=1 contain=1 status=1" \
  "--help prints the usage, the containment rule and the exit statuses"

# `--marker-path` answers a launcher whose lane is on another machine: it
# cannot run this script where the record belongs, so it asks for the path and
# writes the bytes over its own transport. The path is the one the write above
# composes, which is what keeps the two from landing in different places.
new_tree path-mode
PATH_RC=0
PATH_OUT="$("$LANE_MARKER" --marker-path /srv/clone/.git KEN-20 2>&1)" || PATH_RC=$?
assert_eq "rc=$PATH_RC out=$PATH_OUT wrote=$([[ -e "$WT/.git/lane-mail" ]] && echo yes || echo no)" \
  "rc=0 out=/srv/clone/.git/lane-mail/ken-20 wrote=no" \
  "--marker-path lower-cases the item under the common git directory it is given and writes nothing"

# The same path the write composes, asked for both ways against one tree, so a
# launcher writing remotely and the hook reading locally meet on one file.
new_tree agree
mark KEN-21 > /dev/null
AGREE_COMMON="$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)"
assert_eq "asked=$("$LANE_MARKER" --marker-path "$AGREE_COMMON" KEN-21) wrote=$(ls "$WT/.git/lane-mail")" \
  "asked=$AGREE_COMMON/lane-mail/ken-21 wrote=ken-21" \
  "the path --marker-path prints is the one the write puts on disk"

for bad in ../escape 'two words' '' .; do
  PATH_RC=0
  PATH_OUT="$("$LANE_MARKER" --marker-path /srv/clone/.git "$bad" 2>&1)" || PATH_RC=$?
  assert_eq "rc=$PATH_RC first=${PATH_OUT%%$'\n'*}" "rc=2 first=lane-marker: item=invalid" \
    "--marker-path refuses the item [$bad] rather than printing a path it does not name"
done

PATH_RC=0
PATH_OUT="$("$LANE_MARKER" --marker-path /srv/clone/.git 2>&1)" || PATH_RC=$?
assert_eq "rc=$PATH_RC first=${PATH_OUT%%$'\n'*}" "rc=2 first=lane-marker: args=2" \
  "--marker-path without an item is refused"

# The must-fail control: the containment loop gone and nothing else, so the
# planted link is written through. A control that deleted the write instead
# would prove the assertion runs rather than that the rule holds.
MUTANT="$TMP_ROOT/lane-marker-open"
sed -e 's@^  { \[ ! -L "\$path" \] && { \[ ! -e "\$path" \] || \[ -d "\$path" \]; }; } || refuse unsafe "\$path"$@  :@' \
  "$LANE_MARKER" > "$MUTANT"
chmod +x "$MUTANT"
assert_eq "$(cmp -s "$MUTANT" "$LANE_MARKER" && echo same || echo differs)" "differs" \
  "control: the open mutant really removes the containment loop"
CTRL_AWAY="$TMP_ROOT/control-away"
mkdir -p "$CTRL_AWAY"
new_tree control-link
mkdir -p "$WT/tmp"
ln -s -f -n "$CTRL_AWAY" "$WT/tmp/lane-mail"
mark KEN-8 "$MUTANT" > /dev/null
assert_eq "$([[ -d "$CTRL_AWAY/KEN-8" ]] && echo written || echo untouched)" "written" \
  "control: without the containment loop the launch writes through the planted link"

# The must-fail control for the path mode: the lower-casing gone and nothing
# else, so the path a remote launcher is handed names a file lane-mail-check
# never opens while the launch still reports itself marked.
CASE_MUTANT="$TMP_ROOT/lane-marker-cased"
assert_eq "$(grep -c "| tr 'A-Z' 'a-z')" "$LANE_MARKER")" "1" \
  "control: one lower-casing to remove"
sed -e "s@ | tr 'A-Z' 'a-z')@)@" "$LANE_MARKER" > "$CASE_MUTANT"
chmod +x "$CASE_MUTANT"
assert_eq "$("$CASE_MUTANT" --marker-path /srv/clone/.git KEN-20)" "/srv/clone/.git/lane-mail/KEN-20" \
  "control: without the lower-casing the printed path names a file the hook never reads"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
