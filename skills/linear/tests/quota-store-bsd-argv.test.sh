#!/usr/bin/env bash
# bash-runtime: 4
# Surface: linear_quota_store under BSD argv rules. macOS chmod is BSD, and
# getopt(3) there stops at the first non-option argument, so a `--` after the
# mode is a file named `--`: the mode is set, then chmod exits 1. The store
# read that exit as a failed save and reported hold_storage=unavailable. The
# shim on PATH applies the same rule and exit status, as
# commit-guards/tests/bsd-argv-install.test.sh does; the merge-group macOS lane
# does not run the linear suites, so this is the proof a Linux run gives.
set -euo pipefail
export MSYS=winsymlinks:nativestrict
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)" || exit 1
assert_tmpdir TMP_ROOT
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || exit 1
PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/.agents/skills" "$PROJECT/bin" "$TMP_ROOT/home" "$TMP_ROOT/temp"
git -C "$PROJECT" init -q -b main
git -C "$PROJECT" config gc.auto 0
git -C "$PROJECT" config maintenance.auto false
cp -R "$SKILL_DIR" "$PROJECT/.agents/skills/linear"
REAL_CHMOD="$(command -v chmod)"

# BSD chmod: options first, then the mode, then file operands. A `--` among the
# operands is a missing file; the real operands are still processed and the
# exit status is 1. A `--` before the mode ends the options, as in GNU.
cat >"$PROJECT/bin/chmod" <<SH
#!/bin/sh
phase=opts; bad=0; n=\$#
while [ "\$n" -gt 0 ]; do
  arg=\$1; shift; n=\$((n - 1))
  case "\$phase" in
    opts) case "\$arg" in
      --) phase=mode; continue ;;
      -[RfhvHLP]*) set -- "\$@" "\$arg"; continue ;;
      *) phase=files; set -- "\$@" "\$arg"; continue ;;
    esac ;;
    mode) phase=files; set -- "\$@" "\$arg"; continue ;;
    files) if [ "\$arg" = "--" ]; then bad=1; echo "chmod: --: No such file or directory" >&2; continue; fi ;;
  esac
  set -- "\$@" "\$arg"
done
"$REAL_CHMOD" "\$@"; rc=\$?
[ "\$bad" -eq 0 ] || exit 1
exit "\$rc"
SH
cat >"$PROJECT/bin/invoke" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source .agents/skills/linear/scripts/lib/common.sh
LINEAR_AUTH_KIND=api-key LINEAR_API_KEY=fixture-key
linear_quota_response "$(cat "$LOG/headers")" "$(cat "$LOG/body")"
SH
chmod +x "$PROJECT/bin/chmod" "$PROJECT/bin/invoke"

LOG="$TMP_ROOT/log"
mkdir -p "$LOG"
# A reset far in the future needs no injected clock: the header is milliseconds.
printf 'X-RateLimit-Requests-Reset: 99999999999000\r\n' >"$LOG/headers"
jq -cn '{errors:[{message:"Rate limit exceeded.",extensions:{code:"RATELIMITED"}}]}' >"$LOG/body"

# Premise: the shim fails the shape BSD fails after doing the work, and runs the
# real chmod for the shape both accept.
: >"$TMP_ROOT/probe-after" && : >"$TMP_ROOT/probe-before"
shim_rc() { PATH="$PROJECT/bin:$PATH" chmod "$@" >/dev/null 2>&1 && echo 0 || echo $?; }
assert_eq 'premise: chmod with -- after the mode exits 1' "$(shim_rc 700 -- "$TMP_ROOT/probe-after")" 1
assert_eq 'premise: chmod with -- before the mode exits 0' "$(shim_rc -- 700 "$TMP_ROOT/probe-before")" 0

RC=0
OUT=$(cd -- "$PROJECT" && env -i PATH="$PROJECT/bin:$PATH" HOME="$TMP_ROOT/home" TMPDIR="$TMP_ROOT/temp" \
    LOG="$LOG" "$BASH" "$PROJECT/bin/invoke" 2>"$LOG/err") || RC=$?
assert_eq 'a future hold is saved under BSD chmod' "$RC:$(jq -r '.hold_storage' <<<"$OUT")" '0:stored'
record=$(find "$TMP_ROOT/home" -name 'quota-*.json' -type f)
assert 'the hold record exists' test -f "$record"
assert_eq 'the store directory is private' "$(ls -ld "$(dirname -- "$record")" | cut -c1-10)" 'drwx------'
