#!/usr/bin/env bash
# verify-lib's detect_stacks selects the Rust smoke commands from the
# manifest: a workspace declaring `[profile.agent]` builds and tests on that
# profile, and one that does not, or a host with no TOML reader, keeps the
# release commands.
#
# A row is `label|manifest|reader|stack`:
#   manifest  a fixture (see manifest_of): `declared` carries the table,
#             `absent` spells it only inside a comment and a string
#   reader    `host` runs with this host's PATH, `none` with an empty one,
#             on which python3 resolves to nothing
#   stack     the one `name|build|test|cwd` line detect_stacks prints, its
#             pipes rendered as commas so the row separator stays `|`
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C`;
# sourcing verify-lib.sh runs git rev-parse.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$TEST_DIR/../scripts/lib/verify-lib.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$label" "$want" "$got"
  fi
}

# The `declared` row needs the reader on this host; a missing one fails here
# by name rather than as a wrong command.
if python3 -c 'import tomllib' >/dev/null 2>&1; then
  PASS=$((PASS + 1)); printf '  ok    precondition: python3 imports tomllib\n'
else
  FAIL=$((FAIL + 1)); printf '  FAIL  precondition: python3 imports tomllib\n'
fi

# --- the manifests ------------------------------------------------------------
mkdir -p "$TMP_ROOT/declared" "$TMP_ROOT/absent" "$TMP_ROOT/nopath"
cat >"$TMP_ROOT/declared/Cargo.toml" <<'TOML'
[package]
name = "fixture"
version = "0.1.0"

[profile.agent]
inherits = "release"
lto = "off"
TOML
cat >"$TMP_ROOT/absent/Cargo.toml" <<'TOML'
# [profile.agent]
[package]
name = "fixture"
version = "0.1.0"
description = "[profile.agent]"
TOML
manifest_of() {
  case "$1" in
    declared|absent) printf '%s/%s' "$TMP_ROOT" "$1" ;;
    *) echo "UNKNOWN-MANIFEST: $1" >&2; exit 2 ;;
  esac
}
path_of() {
  case "$1" in
    host) printf '%s' "$PATH" ;;
    none) printf '%s' "$TMP_ROOT/nopath" ;;
    *) echo "UNKNOWN-READER: $1" >&2; exit 2 ;;
  esac
}

# detect_stacks in its own shell: the lib is sourced on this host's PATH,
# then the row's PATH is the one the reader is looked up on.
cat >"$TMP_ROOT/drive.sh" <<'DRIVE'
#!/usr/bin/env bash
set -euo pipefail
lib="$1" dir="$2" path="$3"
# shellcheck disable=SC1090
source "$lib"
export PATH="$path"
detect_stacks "$dir"
DRIVE

run() { # manifest reader
  local out
  out="$(bash "$TMP_ROOT/drive.sh" "$LIB" "$(manifest_of "$1")" "$(path_of "$2")" 2>/dev/null)" \
    || out="detect_stacks exited $?"
  printf '%s' "$out" | tr '|' ','
}

run_table() {
  local title="$1" rows="$2" label manifest reader stack got row field before=$((PASS + FAIL))
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r label manifest reader stack <<<"$row"
    for field in "$label" "$manifest" "$reader" "$stack"; do
      [[ "$field" != "" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    got="$(run "$manifest" "$reader")"
    assert_eq "$got" "$stack" "$label"
  done <<<"$rows"
  # At least one row asserted, and every listed row.
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "no row was asserted" >&2; exit 2; }
  [[ "$((PASS + FAIL - before))" -eq "$(printf '%s\n' "$rows" | grep -c '|')" ]] || { echo "not every listed row was asserted" >&2; exit 2; }
}

AGENT='rust,cargo build --profile agent,cargo test --profile agent,.'
RELEASE='rust,cargo build --release,cargo test --release,.'

run_table "the Rust smoke commands per manifest" "\
a declared agent profile is what the stack builds and tests on|declared|host|$AGENT
a manifest without the table keeps the release commands|absent|host|$RELEASE
a host without a TOML reader keeps the release commands|declared|none|$RELEASE
"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
