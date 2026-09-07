#!/usr/bin/env bash
# The CLI launch's time limit: the built-in default, the caller's override
# by environment and by flag, a zero refused (to GNU timeout it means no
# limit), and a host without a timeout binary, which warns, launches the CLI
# directly under the runtime's process-group wrapper and still writes the
# review. What the launch does to the CLI's process tree is
# process-tree.test.sh's.
#
# The script runs from a hermetic copy of the skill: the checkout's own
# settings name a timeout, which would stand in for the built-in default. A
# recording shim named `timeout` sits first on PATH and hands its arguments
# to the real binary (or runs the command where a host has none), so a row
# pins the argv the launch executed and not only the line it logged.
#
# A row is `label|world|argv|rc|out|err|state`; the world's words are the stub
# world's (lib/stub-cli-world.bash) plus:
#   notimeout  a PATH with timeout and gtimeout hidden
# The state adds:
#   limit=<N>s  the header's timeout
#   launch=<the cmd lines>  the timeout binary as `timeout`, the runtime as
#     `runtime`, its stderr capture as `<stderr>`, the CLI as `claude`
#   exec=<the argv the shim received>  aliased the same way; `-` when no
#     timeout ran

# shellcheck source=lib/stub-cli-world.bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/stub-cli-world.bash"

# The hermetic copy: a repository of its own, no settings file.
PROJ="$TMP_ROOT/proj"
mkdir -p "$PROJ/skills"
git init -q "$PROJ"
cp -R "$SKILL_DIR" "$PROJ/skills/second-opinion"
HERMETIC="$PROJ/skills/second-opinion/scripts/second-opinion"
# The recording shim: its argv appended to the row's record, then the real
# binary; a host with neither (a stock Mac) runs the command after the four
# leading arguments. The farm below hides it again.
REAL_TIMEOUT="$(command -v timeout || command -v gtimeout || true)"
TBIN="$TMP_ROOT/tbin"
mkdir -p "$TBIN"
cat >"$TBIN/timeout" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >>"\$TIMEOUT_RECORD"
[[ -z "$REAL_TIMEOUT" ]] || exec "$REAL_TIMEOUT" "\$@"
shift 4
exec "\$@"
SH
chmod +x "$TBIN/timeout"
PATH="$TBIN:$PATH"
export PATH
TIMEOUT_BIN="$TBIN/timeout"

# A PATH without timeout or gtimeout; the rows that need it are skipped out
# loud where the farm cannot be built.
NOTIMEOUT="$TMP_ROOT/notimeout"
path_farm_without "$NOTIMEOUT" timeout gtimeout
NOTIMEOUT_OK=true
if PATH="$NOTIMEOUT" command -v timeout >/dev/null 2>&1 || PATH="$NOTIMEOUT" command -v gtimeout >/dev/null 2>&1 \
  || ! PATH="$NOTIMEOUT" command -v git >/dev/null 2>&1; then
  NOTIMEOUT_OK=false
fi

suite_reset() {
  W_SCRIPT="$HERMETIC"
  W_ENV+=("TIMEOUT_RECORD=$ROW/timeout-argv")
}

suite_word() {
  case "$1" in
    notimeout) W_ENV+=("PATH=$TMP_ROOT/psbin:$TMP_ROOT/bin:$NOTIMEOUT") ;;
    *) echo "UNKNOWN-WORD: $1" >&2; exit 2 ;;
  esac
}

suite_err_word() {
  case "$1" in
    no-timeout) printf 'Warning: no timeout or gtimeout on PATH — external CLI calls will run without a time limit\n' ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s\n' "$1" ;;
  esac
}

launch_text() {
  sed -e "s|^$TIMEOUT_BIN |timeout |" -e "s|$HERMETIC-runtime|runtime|" -e "s|$ROW_TMP/[^ ]*|<stderr>|" -e "s|$STUB\$|claude|" | paste -s -d ';' -
}
extra_state() {
  local limit launch exec=""
  limit="$(sed -n 's/^→ second-opinion: .* timeout=\([^ ]*\)$/\1/p' "$ROW/stderr" | head -n 1)"
  launch="$(sed -n 's/^→ cmd: //p' "$ROW/stderr" | launch_text)"
  [[ ! -f "$ROW/timeout-argv" ]] || exec="$(launch_text <"$ROW/timeout-argv")"
  printf ' limit=%s launch=%s exec=%s' "${limit:--}" "${launch:--}" "${exec:--}"
}

OK="0|<out>|header:review written|calls=1 files=out=review:external-claude:Clean home=absent tmp=0 dirty=-"
NONE="0|<out>|no-timeout header:review written|calls=1 files=out=review:external-claude:Clean home=absent tmp=0 dirty=-"
WRAP="runtime group-run <stderr> claude"
rows="\
the built-in default is 1080s, run under timeout in the foreground with a 30s kill grace, the CLI last|-|review|$OK limit=1080s launch=timeout --foreground -k 30 1080s $WRAP exec=--foreground -k 30 1080 $WRAP
the caller's environment overrides the default|timeout:7|review|$OK limit=7s launch=timeout --foreground -k 30 7s $WRAP exec=--foreground -k 30 7 $WRAP
the flag overrides the environment|timeout:7|review --timeout 9|$OK limit=9s launch=timeout --foreground -k 30 9s $WRAP exec=--foreground -k 30 9 $WRAP
a zero is refused before the header: to GNU timeout it means no limit at all|-|review --timeout 0|1|-|timeout-invalid|calls=0 files=- home=absent tmp=0 dirty=- limit=- launch=- exec=-
"
[[ "$NOTIMEOUT_OK" == false ]] || rows="${rows}\
no timeout binary: a warning, a direct launch under the same wrapper, the review still written|notimeout|review|$NONE limit=1080s launch=direct $WRAP exec=-
no timeout binary keeps the caller's override in the header|notimeout timeout:7|review|$NONE limit=7s launch=direct $WRAP exec=-
"
[[ "$NOTIMEOUT_OK" == true ]] || printf '  skip  the no-timeout rows (no PATH with git but without timeout)\n'
run_table "the launch's time limit" "" "$rows"
finish
