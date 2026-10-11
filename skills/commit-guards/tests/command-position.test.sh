#!/usr/bin/env bash
# Surface: command-position selection and data masking.
# Inputs: skills/commit-guards/scripts/lib/command-position.sh.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)"
READER="${READER_UNDER_TEST:-$ROOT/scripts/lib/command-position.sh}"
# shellcheck source=../scripts/lib/command-position.sh
source "$READER"
TMP_ROOT="$(mktemp -d)" || { echo 'command-position.test: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'command-position.test: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'command-position.test: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
failed=0
while IFS='|' read -r label expected encoded; do
  printf -v command '%b' "$encoded"
  command_segments "$command"
  actual=""
  while IFS= read -r segment; do
    command_text "$segment"
    while IFS= read -r selected; do
      [ -n "$selected" ] || continue
      word=${selected%%[[:space:]]*}
      actual=${actual:+$actual,}$word
    done <<<"$COMMAND_TEXTS"
  done <<<"$SEGMENTS"
  if [ "$actual" = "$expected" ]; then printf 'PASS %s\n' "$label"
  else printf 'FAIL %s: expected=[%s] actual=[%s]\n' "$label" "$expected" "$actual"; failed=$((failed + 1)); fi
done <<'ROWS'
ordinary argument|echo|echo pkill
quoted command argument|echo|echo 'pkill -f x'
quoted command word|pkill|"pkill" -f x
path command word|pkill|/usr/bin/pkill -f x
assignment prefix|pkill|X=1 pkill -f x
control prefix|rm,echo,fi|if rm "$X"; then echo done; fi
launcher prefix|killall|sudo killall node
and command position|true,pkill|true && pkill -f x
or command position|false,pkill|false || pkill -f x
pipe command position|echo,pkill|echo x | pkill -f x
subshell command position|pkill|(pkill -f x)
heredoc body|cat|cat <<'EOF'\npkill -f x\nEOF
multiple heredoc bodies|cat|cat <<'FIRST' <<'SECOND'\npkill -f x\nFIRST\npkill -f y\nSECOND
command after heredoc|cat,pkill|cat <<'EOF'\npkill -f x\nEOF\npkill -f y
ordinary terminator needs exact spelling|cat,pkill,EOF|cat <<EOF\npkill -f x\n\tEOF
tab-stripped terminator|cat|cat <<-EOF\npkill -f x\n\tEOF
quoted shell text|bash,pkill|bash -c 'pkill -f x'
quoted git log text|git|git log --grep='git reset --hard'
continued command word|pkill|pki\\\nll -f x
ROWS
if [ -z "${READER_UNDER_TEST:-}" ]; then
  mutant="$TMP_ROOT/command-position.sh"
  awk '/^    COMMAND_TEXTS=\$rest\$NL/ { print; print "    COMMAND_TEXTS=$COMMAND_TEXTS${rest#*[[:space:]]}$NL"; changed++; next }
    { print } END { if (changed != 1) exit 1 }' "$READER" >"$mutant" || exit 1
  cmp -s -- "$READER" "$mutant" && exit 1
  rc=0
  env -i HOME="$HOME" PATH="$PATH" READER_UNDER_TEST="$mutant" "$BASH" "${BASH_SOURCE[0]}" >"$TMP_ROOT/control.log" 2>&1 || rc=$?
  if [ "$rc" = 1 ] && grep -q '^FAIL ordinary argument:' "$TMP_ROOT/control.log"; then
    printf 'PASS control argument selection\n'
  else cat "$TMP_ROOT/control.log"; failed=$((failed + 1)); fi
fi
[ "$failed" = 0 ]
