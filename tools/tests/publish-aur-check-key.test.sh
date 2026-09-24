#!/usr/bin/env bash
# tools/publish-aur --check-key: the proof the publish workflow runs on the
# AUR key before any clone. The keys are real, made by ssh-keygen; ssh is a
# stub standing in for aur.archlinux.org, which greets a key registered to
# an account the way the AUR does (`Welcome to AUR, <account>!` on stderr,
# exit 1) and refuses any other key with `Permission denied (publickey)`.
#
# A run renders as `rc=<n> keys=<k=v,...>`: the exit status and every
# `publish-aur: <key>=<value>` line, stdout and stderr together, in order.
# FP stands for the fingerprint of the key the row offers. The English under
# a keyed line is not pinned.
#
# The rows table is `label|key|aur|rc|keys`:
#   key  the file offered: `good` an unencrypted ed25519 key, `locked` one
#        behind a passphrase, `junk` a file holding no key
#   aur  what the stub AUR holds: `vanillagreen` or `someone` registers the
#        good key to that account, `none` registers no key, `hostkey` fails
#        the way ssh does on a host key mismatch
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/../.." && pwd)"
TMP="$(mktemp -d)" || { echo "publish-aur-check-key.test: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

command -v ssh-keygen >/dev/null 2>&1 || {
  echo 'ssh-keygen is required: the rows offer real keys' >&2
  exit 1
}

ssh-keygen -q -t ed25519 -N '' -C good -f "$TMP/good"
ssh-keygen -q -t ed25519 -N 'secret' -C locked -f "$TMP/locked"
printf 'not a key\n' >"$TMP/junk"
chmod 600 "$TMP/junk"
FP="$(ssh-keygen -l -f "$TMP/good.pub")" || { echo "publish-aur-check-key.test: cannot fingerprint the good key" >&2; exit 1; }
FP="${FP#* }"
FP="${FP%% *}"
case "$FP" in
  SHA256:*) ;;
  *) echo "publish-aur-check-key.test: the fingerprint extractor is broken: $FP" >&2; exit 1 ;;
esac

# The stub AUR: $TMP/aur names the answer, $TMP/calls counts logins.
mkdir -p -- "$TMP/bin"
cat >"$TMP/bin/ssh" <<STUB
#!/bin/sh
echo call >>"$TMP/calls"
key=
while [ \$# -gt 0 ]; do
  case "\$1" in
    -i) key="\$2"; shift ;;
  esac
  shift
done
aur="\$(cat "$TMP/aur")"
if [ "\$aur" = hostkey ]; then
  echo "Host key verification failed." >&2
  exit 255
fi
offered="\$(ssh-keygen -l -f "\$key" 2>/dev/null | cut -d' ' -f2)"
if [ "\$aur" != none ] && [ "\$offered" = "$FP" ]; then
  echo "Welcome to AUR, \$aur! Interactive shell is disabled." >&2
  echo "Try \\\`ssh aur@aur.archlinux.org help\\\` for a list of commands." >&2
  exit 1
fi
echo "aur@aur.archlinux.org: Permission denied (publickey)." >&2
exit 255
STUB
chmod +x "$TMP/bin/ssh"

# run AUR ARGV... — sets RC, OUT, KEYS, CALLS
run() {
  local line
  printf '%s\n' "$1" >"$TMP/aur"
  shift
  : >"$TMP/calls"
  RC=0
  OUT="$(env -i PATH="$TMP/bin:$PATH" HOME="$TMP" "$ROOT/tools/publish-aur" "$@" 2>&1)" || RC=$?
  KEYS=""
  while IFS= read -r line; do
    case "$line" in
      'publish-aur: '*) KEYS="$KEYS,${line#publish-aur: }" ;;
    esac
  done <<<"$OUT"
  KEYS="${KEYS#,}"
  [ -n "$KEYS" ] || KEYS="-"
  CALLS="$(wc -l <"$TMP/calls" | tr -d ' ')"
}

rows="
registered to the maintaining account|good|vanillagreen|0|fingerprint=FP,account=vanillagreen
registered to another account|good|someone|1|fingerprint=FP,account=someone
not registered|good|none|1|fingerprint=FP,unregistered=FP
host key mismatch|good|hostkey|1|fingerprint=FP,login=255
passphrase-protected key|locked|vanillagreen|1|keyfile=$TMP/locked
not a key|junk|vanillagreen|1|keyfile=$TMP/junk
"
while IFS='|' read -r label key aur rc keys; do
  [ -n "$label" ] || continue
  want="${keys//FP/$FP}"
  run "$aur" --check-key "$TMP/$key"
  if [ "$RC" = "$rc" ] && [ "$KEYS" = "$want" ]; then
    ok "$label: rc=$rc keys=$keys"
  else
    bad "$label: want rc=$rc keys=$want" "got rc=$RC keys=$KEYS
$OUT"
  fi
  # A key with no public half never reaches the AUR; every other row logs in once.
  case "$key" in
    good) calls=1 ;;
    *) calls=0 ;;
  esac
  if [ "$CALLS" = "$calls" ]; then
    ok "$label: $calls login(s)"
  else
    bad "$label: want $calls login(s)" "got $CALLS"
  fi
done <<<"$rows"

run vanillagreen --check-key
if [ "$RC" = 2 ] && [ "$KEYS" = "option=--check-key" ] && [ "$CALLS" = 0 ]; then
  ok "no key file: rc=2 keys=$KEYS"
else
  bad "no key file: want rc=2 keys=option=--check-key" "got rc=$RC keys=$KEYS calls=$CALLS
$OUT"
fi

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
