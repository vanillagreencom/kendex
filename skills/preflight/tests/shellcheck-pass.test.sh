#!/usr/bin/env bash
# The shellcheck pass judges every changed shell file once, side by side.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
PF="${PREFLIGHT_UNDER_TEST:-$PF}"

TMP_ROOT="$(mktemp -d)" || { echo 'shellcheck-pass: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "shellcheck-pass: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'shellcheck-pass: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# Each stub call registers, then reports its file only once a second call has
# registered too: a call that runs alone until the deadline reports nothing,
# so a sequential pass loses its first file's finding.
mkdir -p "$TMP_ROOT/bin"
printf '#!%s\n' "$BASH" > "$TMP_ROOT/bin/shellcheck"
cat >> "$TMP_ROOT/bin/shellcheck" <<'STUB'
set -euo pipefail
for path; do :; done
mktemp "$PF_SC_CALLS/call.XXXXXX" > /dev/null
tries=0
while :; do
  calls=("$PF_SC_CALLS"/call.*)
  [ "${#calls[@]}" -lt 2 ] || break
  tries=$((tries + 1))
  [ "$tries" -lt 200 ] || exit 0
  sleep 0.05
done
printf '%s:2:1: error: planted [SC9999]\n' "$path"
exit 1
STUB
printf '#!%s\nprintf "%%s\\n" "$PF_SC_WORKERS"\n' "$BASH" > "$TMP_ROOT/bin/getconf"
chmod +x "$TMP_ROOT/bin/shellcheck" "$TMP_ROOT/bin/getconf"
export PATH="$TMP_ROOT/bin:$PATH"

NL='
'
while IFS='|' read -r name workers first_reported; do
  R="$TMP_ROOT/$name"
  mkdir -p "$R/scripts"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  git -C "$R" config gc.auto 0
  git -C "$R" config maintenance.auto false
  printf '# Fixture\n' > "$R/README.md"
  git -C "$R" add README.md
  git -C "$R" commit -qm baseline
  expected=''
  for n in 1 2 3 4 5 6; do
    printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf fixture\n' > "$R/scripts/file$n.sh"
    [ "$n" -lt "$first_reported" ] || expected="$expected${expected:+$NL}scripts/file$n.sh:2: [shellcheck-errors]"
  done
  printf 'not shell\n' > "$R/notes.txt"
  git -C "$R" add -A
  export PF_SC_CALLS="$TMP_ROOT/$name.calls" PF_SC_WORKERS="$workers"
  mkdir "$PF_SC_CALLS"
  run_pf --staged
  calls=("$PF_SC_CALLS"/call.*)
  if [ "$RC" = 1 ] && [ "$(pf_fired)" = "$expected" ] && [ "${#calls[@]}" = 6 ]; then
    ok "$name"
  else
    bad "$name" "rc=$RC calls=${#calls[@]} fired=[$(pf_fired)]"
  fi
done <<'ROWS'
files-run-side-by-side|4|1
one-worker-control|1|2
ROWS

pf_summary
