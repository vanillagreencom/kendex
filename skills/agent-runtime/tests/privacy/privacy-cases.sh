#!/usr/bin/env bash
# The effect engine's privacy across the crate boundary, proved by the
# compiler: each case under cases/ is planted into a copy, and the one cargo
# command it names must refuse it with the error code or the disallowed path
# its header expects. A rustdoc `compile_fail` test cannot hold these: stable
# rustdoc passes it on any compile error.
#
# Usage: privacy-cases.sh [CASE...]
#   CASE is a file name under cases/ without `.rs`; none runs every case.
# Each case file starts with two header lines:
#   // expect: E0603            (cargo check: this error code is reported)
#   // expect: disallowed PATH  (cargo clippy -D warnings: this path refused)
#   // holds: <the invariant>
# An error-code case is planted as the body of a function of an outside crate
# that depends on agent-runtime, with `op: &mut Operation` and
# `owned: Operation` in scope: a caller's view of the engine. A disallowed
# case is planted as the body of a function in agent-runtime's own `intent`
# module, outside the engine. CARGO_TARGET_DIR is honoured for the builds;
# it defaults to a folder under the copy, removed at exit.
# Prints `PASS|FAIL <case> expected=<...> found=<...>` per case; exits 1 on
# any FAIL.
# bash-runtime: 3.2
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
skills="$(cd "$here/../../.." && pwd)"
root="$(mktemp -d "${TMPDIR:-/tmp}/privacy-cases.XXXXXX")"
trap 'rm -rf -- "$root"' EXIT

mkdir -p "$root/skills/agent-runtime/tests" "$root/case/src"
cp -R "$skills/agent-runtime/runtime" "$root/skills/agent-runtime/runtime"
cp -R "$skills/agent-runtime/tests/rust" "$root/skills/agent-runtime/tests/rust"
manifest="$root/skills/agent-runtime/runtime/Cargo.toml"
target="${CARGO_TARGET_DIR:-$root/target}"
inside="$root/skills/agent-runtime/runtime/src/intent.rs"
cp "$inside" "$root/intent.rs.clean"
cp "$root/skills/agent-runtime/runtime/Cargo.lock" "$root/case/Cargo.lock"
cat > "$root/case/Cargo.toml" <<'EOF'
[package]
name = "privacy-case"
version = "0.0.0"
edition = "2024"
publish = false

[workspace]

[dependencies]
agent-runtime = { path = "../skills/agent-runtime/runtime" }
EOF

if [ "$#" -eq 0 ]; then
  set --
  for file in "$here"/cases/*.rs; do
    name="$(basename "$file")"
    set -- "$@" "${name%.rs}"
  done
fi

failed=0
for case_name in "$@"; do
  file="$here/cases/$case_name.rs"
  expect="$(sed -n '1s#^// expect: ##p' "$file")"
  cp "$root/intent.rs.clean" "$inside"
  log="$root/$case_name.log"
  case "$expect" in
    disallowed\ *)
      wanted="${expect#disallowed }"
      {
        printf '\n#[allow(dead_code, unused_variables)]\n'
        printf 'fn privacy_case() {\n'
        sed '1,2d' "$file"
        printf '}\n'
      } >> "$inside"
      status=0
      CARGO_TARGET_DIR="$target" cargo clippy --offline --quiet --lib \
        --manifest-path "$manifest" -- -D warnings > "$log" 2>&1 || status=$?
      if [ "$status" -ne 0 ] && grep -qF "use of a disallowed method \`$wanted\`" "$log"; then
        found="$wanted"
      else
        found="exit=$status"
      fi
      ;;
    E*)
      wanted="$expect"
      {
        printf '#![allow(dead_code, unused_variables, unused_mut)]\n'
        printf 'pub fn privacy_case(\n'
        printf '    op: &mut agent_runtime::effects::Operation<'"'"'_>,\n'
        printf '    owned: agent_runtime::effects::Operation<'"'"'_>,\n'
        printf ') {\n'
        sed '1,2d' "$file"
        printf '}\n'
      } > "$root/case/src/lib.rs"
      status=0
      CARGO_TARGET_DIR="$target" cargo check --offline --quiet --lib \
        --manifest-path "$root/case/Cargo.toml" > "$log" 2>&1 || status=$?
      found="$({ grep -o 'error\[E[0-9]*\]' "$log" || true; } | sed 's/error\[\(.*\)\]/\1/' | sort -u | tr '\n' ' ')"
      found="${found% }"
      ;;
    *)
      echo "FAIL $case_name: no expect header" >&2
      failed=1
      continue
      ;;
  esac
  case " $found " in
    *" $wanted "*) [ "$status" -ne 0 ] && echo "PASS $case_name expected=$wanted found=$found" && continue ;;
  esac
  echo "FAIL $case_name expected=$wanted found=${found:-none}"
  sed -n '1,40p' "$log" >&2
  failed=1
done
exit "$failed"
