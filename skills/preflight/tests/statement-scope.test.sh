#!/usr/bin/env bash
# The statement reader runs only when a substitution rule can report a finding.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
PF="${PREFLIGHT_UNDER_TEST:-$PF}"

TMP_ROOT="$(mktemp -d)" || { echo 'statement-scope: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "statement-scope: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'statement-scope: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# Prefix parsing passes only -n and reads stdin. Whole-file syntax checks
# also pass a filename. The wrapper counts the former and runs real Bash.
mkdir -p "$TMP_ROOT/bin"
printf '#!%s\n' "$BASH" > "$TMP_ROOT/bin/bash"
cat >> "$TMP_ROOT/bin/bash" <<'WRAPPER'
set -euo pipefail
if [ "$#" = 1 ] && [ "$1" = -n ]; then
  printf 'prefix\n' >> "$PF_PREFIX_LOG"
fi
exec "$PF_REAL_BASH" "$@"
WRAPPER
chmod +x "$TMP_ROOT/bin/bash"
export PF_REAL_BASH="$BASH"
export PF_PREFIX_LOG="$TMP_ROOT/prefix.log"
export PATH="$TMP_ROOT/bin:$PATH"

while IFS='|' read -r name tree mode count expected_rc expected_fired expected_parse expected_probes; do
  R="$TMP_ROOT/$name"
  mkdir -p "$R/$tree"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  git -C "$R" config gc.auto 0
  git -C "$R" config maintenance.auto false
  printf '# Fixture\n' > "$R/README.md"
  git -C "$R" add README.md
  git -C "$R" commit -qm baseline
  n=0
  while [ "$n" -lt "$count" ]; do
    n=$((n + 1))
    {
      printf '#!/usr/bin/env bash\n'
      case "$mode" in
        strict | tail | pending | long-pending | nested | compound) printf 'set -euo pipefail\n' ;;
        relaxed) printf 'set -euo pipefail\nset +e\n' ;;
        unchecked) printf '# No errexit\n' ;;
      esac
      if [ "$mode" = compound ]; then
        printf 'f() {\n  if true; then\n    ROOT="$(git rev-parse --show-toplevel)"\n    [ -z "$ROOT" ] && exit 1\n  fi\n}\nf\n'
      elif [ "$mode" = pending ]; then
        printf 'ROOT="$(\n  printf old\n)"\n[ -z "$ROOT" ] && exit 1\n'
      elif [ "$mode" = long-pending ]; then
        printf 'ROOT="$(\n'
        i=0
        while [ "$i" -lt 24 ]; do
          i=$((i + 1))
          printf '  printf café\n'
        done
        printf ')"\n[ -z "$ROOT" ] && exit 1\n'
      elif [ "$mode" = nested ]; then
        cat <<'NESTED'
ROOT="$(
  printf 'a
) literal
b'
)"
[ -z "$ROOT" ] && exit 1
NESTED
      elif [ "$mode" = tail ]; then
        printf 'printf old\n'
        i=0
        while [ "$i" -lt 24 ]; do
          i=$((i + 1))
          printf 'ROOT="$(printf fixture)" || exit 1\nprintf "%%s\\n" "$ROOT"\n'
        done
      elif [ "$mode" = unchecked ]; then
        printf 'ROOT="$(mktemp -d)"\nprintf "%%s\\n" "$ROOT"\n'
      else
        printf 'ROOT="$(git rev-parse --show-toplevel)"\n[ -z "$ROOT" ] && exit 1\n'
      fi
    } > "$R/$tree/file$n.sh"
  done
  case "$mode" in
    tail | pending)
      git -C "$R" add -A
      git -C "$R" commit -qm 'unchanged statement tail'
      n=0
      while [ "$n" -lt "$count" ]; do
        n=$((n + 1))
        sed 's/printf old/printf changed/' "$R/$tree/file$n.sh" > "$TMP_ROOT/changed"
        mv "$TMP_ROOT/changed" "$R/$tree/file$n.sh"
      done
      ;;
  esac
  git -C "$R" add -A
  : > "$PF_PREFIX_LOG"
  run_pf --staged
  got="$(pf_fired)"
  [ -n "$got" ] || got=-
  parsed=0
  [ ! -s "$PF_PREFIX_LOG" ] || parsed=1
  probes="$(wc -l < "$PF_PREFIX_LOG" | tr -d ' ')"
  bounded=1
  if [ "$expected_probes" != - ] && [ "$probes" -gt "$expected_probes" ]; then bounded=0; fi
  if [ "$RC" = "$expected_rc" ] && [ "$got" = "$expected_fired" ] && [ "$parsed" = "$expected_parse" ] && [ "$bounded" = 1 ]; then
    ok "$name"
  else
    bad "$name" "rc=$RC fired=$got parsed=$parsed probes=$probes; expected rc=$expected_rc fired=$expected_fired parsed=$expected_parse probes=$expected_probes"
  fi
done <<'ROWS'
many-strict-test-files|tests|strict|24|0|-|0|-
many-unchanged-statement-tails|scripts|tail|24|0|-|0|-
strict-test-control|tests|unchecked|1|1|tests/file1.sh:3: [fail-open]|1|-
strict-authored-control|scripts|strict|1|1|scripts/file1.sh:3: [fail-open]|1|-
relaxed-authored-file|scripts|relaxed|1|0|-|0|-
changed-line-inside-pending-statement|scripts|pending|1|1|scripts/file1.sh:3: [fail-open]|1|-
long-pending-statement-retains-finding|scripts|long-pending|1|1|scripts/file1.sh:3: [fail-open]|1|4
native-delimiter-changes-retain-finding|scripts|nested|1|1|scripts/file1.sh:3: [fail-open]|1|6
compound-context-is-retained|scripts|compound|1|1|scripts/file1.sh:5: [fail-open]|1|-
ROWS

pf_summary
