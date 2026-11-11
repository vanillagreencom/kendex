#!/usr/bin/env bash
# Surface: the mailbox's orch paths, scripts/lane-mail, lib/file-lock.sh and
# lib/mailbox-append.sh, which consumers run and source by the orch name.
# Inputs: skills/orch/scripts/** skills/mailbox/scripts/**
# Each row lays the files out as an install renders them, the orch package
# beside the mailbox package, and runs the real mailbox through the orch path.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"
ORCH_SCRIPTS="$TEST_DIR/../scripts"
MAILBOX_SCRIPTS="$TEST_DIR/../../mailbox/scripts"
TMP_ROOT="$(mktemp -d)" || { echo 'orch_mail_paths: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'orch_mail_paths: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'orch_mail_paths: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
# No row reaches a tmux server; a call that tried would fail here, not reach
# the operator's.
mkdir "$TMP_ROOT/bin"
printf '#!/bin/sh\nexit 1\n' > "$TMP_ROOT/bin/tmux"
chmod +x "$TMP_ROOT/bin/tmux"
PATH="$TMP_ROOT/bin:$PATH"

# An installed clone: the orch and mailbox packages' scripts under
# .agents/skills, as an install places them side by side.
layout() { # NAME — prints the clone root
  local clone="$TMP_ROOT/$1"
  mkdir -p "$clone/.agents/skills/orch" "$clone/.agents/skills/mailbox"
  cp -R -- "$ORCH_SCRIPTS" "$clone/.agents/skills/orch/scripts"
  cp -R -- "$MAILBOX_SCRIPTS" "$clone/.agents/skills/mailbox/scripts"
  git -C "$clone" init -q
  git -C "$clone" config gc.auto 0
  git -C "$clone" config maintenance.auto false
  mkdir -p "$clone/tmp/lane-mail/KEN-1" "$clone/tmp/lane-mail/KEN-2"
  printf '%s' "$clone"
}

# A directive sent through the orch lane-mail, then read back through the
# mailbox's own lane-mail: VERDICT is `RC|RECEIPT KEY|TEXT READ`.
VERDICT=""
send_through() { # CLONE
  local clone="$1" rc=0 receipt="" read=""
  printf 'Through the orch path.\n' > "$clone/directive"
  receipt="$(cd -- "$clone" && "$clone/.agents/skills/orch/scripts/lane-mail" send --item KEN-1 --root "$clone" \
    --directive --file "$clone/directive" 2>"$clone/send.err")" || rc=$?
  read="$(cd -- "$clone" && "$clone/.agents/skills/mailbox/scripts/lane-mail" inbox --item KEN-1 --root "$clone" 2>/dev/null)" || :
  case "$read" in *'Through the orch path.'*) read=text ;; *) read=none ;; esac
  VERDICT="$rc|${receipt%% id=*}|$read"
}

# The released remote append: the library text a released lane-host-ssh runs
# on a host clone, sourcing the two orch libraries by that path and appending
# one envelope under the mailbox's lock. VERDICT is `RC|BOX BYTES|NOTICE`.
APPEND_LIBRARIES='lib="$3/.agents/skills/orch/scripts/lib"
for library in file-lock.sh mailbox-append.sh; do
  if [ ! -r "$lib/$library" ]; then
    printf '\''lane-host-ssh: append-library-missing path=%s\n'\'' "$lib/$library" >&2
    printf '\''the host clone predates the append verb; refresh it to a build carrying that library\n'\'' >&2
    exit 1
  fi
  . "$lib/$library"
done
if ! declare -F mailbox_duplicate_id >/dev/null; then
  printf '\''lane-host-ssh: append-library-outdated path=%s repeat-check=skipped\n'\'' "$lib/mailbox-append.sh" >&2
fi
'
append_through() { # CLONE
  local clone="$1" rc=0 box="$1/tmp/lane-mail/KEN-2/to-lane.jsonl" bytes notice
  printf '{"id":"orch-path-1","kind":"directive","text":"appended"}\n' > "$clone/staged"
  "$BASH" -c "set -euo pipefail
$APPEND_LIBRARIES"'mailbox_append_locked "$1" 30 "" "$2" < "$2"' lane-host-ssh \
    "$box" "$clone/staged" "$clone" 2>"$clone/append.err" || rc=$?
  bytes=absent
  [[ ! -f "$box" ]] || { cmp -s -- "$box" "$clone/staged" && bytes=staged || bytes=other; }
  notice="$(sed -n 's/^lane-host-ssh: \([a-z-]*\).*/\1/p' "$clone/append.err")"
  VERDICT="$rc|$bytes|${notice:-none}"
}

CLONE="$(layout installed)"
send_through "$CLONE"
assert_eq "$VERDICT" '0|lane-mail: sent item=KEN-1|text' 'the orch lane-mail delivers through the mailbox and prints its receipt' "$CLONE/send.err"
RC=0
(cd -- "$CLONE" && "$CLONE/.agents/skills/orch/scripts/lane-mail" inbox --item .. >/dev/null 2>"$CLONE/refuse.err") || RC=$?
assert_eq "$RC|$(sed -n '1s/=.*//p' "$CLONE/refuse.err")" '2|lane-mail: item-invalid' 'the orch lane-mail forwards the mailbox refusal and its exit'
append_through "$CLONE"
assert_eq "$VERDICT" '0|staged|none' 'a released remote append sources both orch libraries and lands the envelope' "$CLONE/append.err"

# Controls: an orch path that no longer reaches the mailbox package.
MUTANT="$(layout control-exec)"
mutate_file "$MUTANT/.agents/skills/orch/scripts/lane-mail" '/../../mailbox/scripts/lane-mail' '/../mailbox/scripts/lane-mail'
send_through "$MUTANT"
assert_eq "$VERDICT" '127||none' 'control: an orch lane-mail aimed past the mailbox delivers nothing'
MUTANT="$(layout control-source)"
mutate_file "$MUTANT/.agents/skills/orch/scripts/lib/file-lock.sh" '/mailbox/scripts/lib/file-lock.sh"' '/mailbox/scripts/lib/file-lock-gone.sh"'
append_through "$MUTANT"
assert_eq "$VERDICT" '1|absent|none' 'control: an orch file-lock.sh that sources nothing appends nothing'

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
