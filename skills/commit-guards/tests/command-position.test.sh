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
while IFS='|' read -r label expected mode encoded; do
  printf -v command '%b' "$encoded"
  command_segments "$command" "$mode"
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
ordinary argument|echo||echo pkill
quoted command argument|echo||echo 'pkill -f x'
quoted command word|pkill||"pkill" -f x
path command word|pkill||/usr/bin/pkill -f x
assignment prefix|pkill||X=1 pkill -f x
control prefix|rm,echo||if rm "$X"; then echo done; fi
launcher prefix|killall||sudo killall node
and command position|true,pkill||true && pkill -f x
or command position|false,pkill||false || pkill -f x
pipe command position|echo,pkill||echo x | pkill -f x
subshell command position|pkill||(pkill -f x)
heredoc body|cat||cat <<'EOF'\npkill -f x\nEOF
multiple heredoc bodies|cat||cat <<'FIRST' <<'SECOND'\npkill -f x\nFIRST\npkill -f y\nSECOND
command after heredoc|cat,pkill||cat <<'EOF'\npkill -f x\nEOF\npkill -f y
ordinary terminator needs exact spelling|cat,pkill,EOF||cat <<EOF\npkill -f x\n\tEOF
tab-stripped terminator|cat||cat <<-EOF\npkill -f x\n\tEOF
quoted shell text|bash,pkill||bash -c 'pkill -f x'
quoted git log text|git||git log --grep='git reset --hard'
continued command word|pkill||pki\\\nll -f x
else arm|true,true,pkill||if true; then true; else pkill x; fi
brace group|pkill||{ pkill x; }
timeout duration|pkill||timeout 5 pkill x
timeout option value|pkill||timeout -s TERM 5 pkill x
nice launcher|pkill||nice pkill x
nice option value|pkill||nice -n 5 pkill x
ionice launcher|pkill||ionice -c 3 pkill x
xargs launcher|pkill||xargs -n 1 pkill x
doas launcher|pkill||doas -u root pkill x
stdbuf launcher|pkill||stdbuf -o L pkill x
setsid launcher|pkill||setsid -w pkill x
nohup launcher|pkill||nohup pkill x
nested launchers|pkill||timeout 5 nice -n 5 pkill x
launcher shell text|bash,pkill||timeout 5 bash -c 'pkill x'
find executable|pkill||find . -exec pkill x \\;
find directory executable|pkill||find . -execdir pkill x \\;
find shell text|sh,rm,{}||find . -exec sh -c 'rm -rf $X' {} \\;
find quoted data|find||find . -name 'sh pkill' -print
launcher quoted data|echo||echo 'timeout 5 pkill x'
command query|command||command -v pkill
prefixed shell heredoc|true,bash,pkill||true; bash <<EOF\npkill x\nEOF
prefixed data heredoc|true,cat||true; cat <<EOF\npkill x\nEOF
pipeline shell heredoc|cat,bash,pkill||cat <<EOF | bash\npkill x\nEOF
pipeline data heredoc|cat,cat||cat <<EOF | cat\npkill x\nEOF
independent shell after data|cat,bash||cat <<EOF && bash -c true\npkill x\nEOF
independent or shell after data|cat,bash||cat <<EOF || bash -c true\npkill x\nEOF
pipeline receiver group|tar|pipes|tar -cf - repo/.git | (cd /tmp/x && tar -xf -)
pipeline brace receiver|tar|pipes|tar -cf - repo/.git | { cd /tmp/x; tar -xf -; }
ROWS
if [ -z "${READER_UNDER_TEST:-}" ]; then
  while IFS='|' read -r defect row; do
    mutant="$TMP_ROOT/$defect.sh"
    awk -v defect="$defect" '
      /^    COMMAND_TEXTS=\$rest\$NL/ && defect == "arguments" {
        print; print "    COMMAND_TEXTS=$COMMAND_TEXTS${rest#*[[:space:]]}$NL"; changed++; next
      }
      /^      owner=/ && defect == "heredoc-owner" {
        print; print "      owner=$BARE"; changed++; next
      }
      /if runs_shell_text "\$\{receiver%%/ && defect == "heredoc-pipe" {
        print; print "        executable_body=\"\""; changed++; next
      }
      /^    executable=\$word/ && defect == "control-words" {
        print; print "    case $word in else | \\{) COMMAND_TEXTS=$rest$NL; return 0 ;; esac"; changed++; next
      }
      /^    executable=\$word/ && defect == "launchers" {
        print; print "    case $word in timeout | nice | ionice | xargs | doas | stdbuf | setsid) COMMAND_TEXTS=$rest$NL; return 0 ;; esac"; changed++; next
      }
      /takes_value=1; continue/ && defect == "option-value" {
        sub(/takes_value=1;/, "takes_value=1; takes_value=\"\";"); changed++
      }
      /\[ "\$launcher" != timeout \]/ && defect == "duration" {
        print; print "        duration=\"\""; changed++; next
      }
      /if \[ -n "\$found" \]/ && defect == "find-exec" {
        print "        found=\"\""; changed++
      }
      /local pipe_group=/ && defect == "pipe-group" {
        print; print "      pipe_group=\"a^\""; changed++; next
      }
      { print } END { if (changed != 1) exit 1 }
    ' "$READER" >"$mutant" || exit 1
    cmp -s -- "$READER" "$mutant" && exit 1
    rc=0
    env -i HOME="$HOME" PATH="$PATH" READER_UNDER_TEST="$mutant" "$BASH" "${BASH_SOURCE[0]}" >"$TMP_ROOT/$defect.log" 2>&1 || rc=$?
    if [ "$rc" = 1 ] && grep -Fq "FAIL $row:" "$TMP_ROOT/$defect.log"; then
      printf 'PASS control %s\n' "$defect"
    else cat "$TMP_ROOT/$defect.log"; failed=$((failed + 1)); fi
  done <<'CONTROLS'
arguments|ordinary argument
heredoc-owner|prefixed shell heredoc
heredoc-pipe|pipeline shell heredoc
control-words|else arm
launchers|timeout duration
option-value|nice option value
duration|timeout duration
find-exec|find shell text
pipe-group|pipeline receiver group
CONTROLS
fi
[ "$failed" = 0 ]
