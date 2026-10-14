#!/usr/bin/env bash
# Selection assertions shared by the CI selection and queue cases.
mkdir -p "$TMP/rule/tools"
cp -R "$ROOT/tools/lib" "$TMP/rule/tools/lib"
cp "$ROOT/tools/macos-test-contracts" "$ROOT/tools/macos-test-contracts.json" "$TMP/rule/tools/"
cp "$ROOT/tools/rust-reads" "$TMP/rule/tools/rust-reads"
VERIFY_LANES="${VERIFY_ROW% shards=*}"
# The fixture checkouts' rows, where no script or suite reads a path: a
# build input runs `rest`, `refresh` and `orch-rest` for real kendex
# rows, and a tools/ path its suites' two shards and the scans.
BUILD_ROW="$(measured both false true true '["refresh","orch-rest","rest"]' '["refresh","orch-rest","rest"]')"
TOOL_SHARDS='["guards-scans","guards-tools","guards-tools-tail"]'
TOOL_ROW="$(measured both false true false "$TOOL_SHARDS" "$(macos_shards "$TOOL_SHARDS")")"
# Where a shard runs, and where none does. A shard runs on both runners
# unless the diff is prose alone.
SHARD_CODE="$(lanes both false true false)"
SHARD_BUILD="$(lanes both false true true)"
SHARD_PROSE="$(lanes linux false false false)"
NONE_CODE="$(lanes none false true false)"
NONE_PROSE="$(lanes none false false false)"
NO_SKILL="-review-gate -refresh -orch-terminal -orch-oversee -orch-oversee-watch -orch-oversee-succeed -orch-dev -orch-state -orch-rest -guards-commit -guards-commit-tail -linear -linear-controls-a -linear-controls-b -worktree -worktree-restack -rest -slack -mailbox -node -pi-claude-bridge"
ORCH_ALL="+orch-terminal +orch-oversee +orch-oversee-watch +orch-oversee-succeed +orch-dev +orch-state +orch-rest"

# Whether a `shards=` list meets a spec: an exact list, `*` for any, or
# `+shard` members it must hold and `-shard` members it must not. Empty
# where it does.
shards_miss() { # SPEC SHARDS
  local word
  case "$1" in
    '*') return 0 ;;
    '['*) [ "$1" = "$2" ] || printf '%s' "$2"; return 0 ;;
  esac
  for word in $1; do
    case "$word:$2" in
      +*) case "$2" in *"\"${word#+}\""*) ;; *) printf 'missing=%s ' "${word#+}" ;; esac ;;
      -*) case "$2" in *"\"${word#-}\""*) printf 'unexpected=%s ' "${word#-}" ;; esac ;;
    esac
  done
}
# The value of one `name=` word of a selection.
field() { # NAME — reads the selection on stdin
  sed -n "s/.* $1=\([^ ]*\).*/\1/p"
}
# One selection row: its lanes whole and its shards against the spec, or the
# refusal key where LANES is one.
sel_row() { # DESC CLASS DOCS PATHS LANES SPEC
  local got
  got="$(selection "$2" "$3" "$(printf '%s\n' $4)")"
  case "$got" in
    exit=*) check "$1" "$5" "$got" ;;
    # Catalog selection has its own input table below. These rows hold the
    # existing compiler, platform and shard contracts independently.
    *) check "$1" "$(sed 's/ catalog=[^ ]* smoke=[^ ]*//' <<<"$5")|" \
      "$(sed 's/ catalog=[^ ]* smoke=[^ ]*//' <<<"${got% shards=*}")|$(shards_miss "$6" "$(field shards <<<"$got")")" ;;
  esac
}

SETTINGS_TOML="kendex.settings"".toml"
LOCAL_TOML="kendex-local"".toml"
DISCOVER_RS="crates/core/src/discover"".rs"
SKILLS_AGENTS="skills/AGENTS"".md"
UNREAD_DOC="docs/no-reader"".md"
UNREAD_LEGAL="docs/legal/no-reader"".md"
UI_ONLY="ui/src/App.""tsx"
READ_WORLD="$TMP/read-world"
mkdir -p "$READ_WORLD/crates/demo/src"
git init -q "$READ_WORLD"
printf '[package]\nname = "demo"\nversion = "0.1.0"\n' >"$READ_WORLD/crates/demo/Cargo.toml"
printf '[workspace]\nmembers = ["crates/*"]\nresolver = "2"\n' >"$READ_WORLD/Cargo.toml"
for package in core cli app; do
  mkdir -p "$READ_WORLD/crates/$package/src"
  printf '[package]\nname = "kendex-%s"\nversion = "0.1.0"\n' "$package" >"$READ_WORLD/crates/$package/Cargo.toml"
  printf 'fn main() {}\n' >"$READ_WORLD/crates/$package/src/lib.rs"
done
cat >>"$READ_WORLD/crates/cli/Cargo.toml" <<'TOML'
[dependencies]
kendex-core = { path = "../core" }
[[test]]
name = "cli_smoke"
path = "tests/cli_smoke.rs"
TOML
printf '\n[dependencies]\ndemo = { path = "../demo" }\n' >>"$READ_WORLD/crates/core/Cargo.toml"
mkdir -p "$READ_WORLD/crates/cli/tests"
printf '#[path = "../../test_util.rs"]\nmod test_util;\n' >"$READ_WORLD/crates/cli/tests/cli_smoke.rs"
printf 'fn fixture() {}\n' >"$READ_WORLD/crates/test_util.rs"
cat >"$READ_WORLD/crates/demo/src/lib.rs" <<'RS'
const A: &str = include_str!("../../../docs/a.md");
const X: &str = include_str!("../../../assets/x.json");
fn tool() { read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tools/x")); }
fn legal(name: &str) -> PathBuf { PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../docs/legal").join(name) }
fn root() -> PathBuf { Path::new(env!("CARGO_MANIFEST_DIR")).join("../..") }
RS
READ_PROSE_ROW="$(measured none false false false '[]' '[]' true)"
SEL_WORLD="$TMP/sel-world"
mkdir -p "$SEL_WORLD/tools/tests" "$SEL_WORLD/hooks/tests"
cp -R "$READ_WORLD/crates" "$SEL_WORLD/crates"
cp "$READ_WORLD/Cargo.toml" "$SEL_WORLD/Cargo.toml"
skill() { # NAME REQUIRED-LIST — a SKILL.md, with a dependencies block where REQUIRED-LIST is given
  mkdir -p "$SEL_WORLD/skills/$1/scripts" "$SEL_WORLD/skills/$1/tests"
  if [ -n "$2" ]; then
    printf -- '---\nname: %s\ndependencies:\n  optional: [price-handling]\n  commands:\n    - command: agent-browser\n      purpose: Browser automation\n      floor: "0.26.0"\n      packages:\n        npm: agent-browser\n    - command: op\n      purpose: Credential reads\n      optional: true\n  required: [%s]\n  agents: [runtime]\n---\n' "$1" "$2"
  else
    printf -- '---\nname: %s\n---\n' "$1"
  fi >"$SEL_WORLD/skills/$1/SKILL.md"
}
skill github ''
skill worktree commit-guards
skill orch worktree
skill harness-ci ''
skill review-gate harness-ci
skill preflight ''
skill commit-guards ''
skill doc-limits commit-guards
skill price-handling ''
printf '. "$(dirname "$0")/../../github/scripts/lib/gh-auth.sh"\n' >"$SEL_WORLD/skills/worktree/scripts/worktree"
printf '. "$HERE/../../orch/scripts/lib/branch-growth.sh"\n' >"$SEL_WORLD/skills/harness-ci/scripts/change-class"
printf 'run "$R/.agents/skills/preflight/scripts/preflight"\n' >"$SEL_WORLD/skills/commit-guards/tests/scope.test.sh"
printf 'refs "$ROOT/docs/guard/refs.md"\n' >"$SEL_WORLD/skills/commit-guards/tests/refs.test.sh"
printf 'read "$ROOT/kendex.settings.toml" lib/atomic-install.sh README.md\n' >"$SEL_WORLD/tools/tests/settings.test.sh"
printf 'DISCOVER="$TEST_DIR/../../crates/demo/src/discover.rs"\n' >"$SEL_WORLD/hooks/tests/discover.test.sh"
printf 'policy "$ROOT/docs/x/policy.md"\n' >"$SEL_WORLD/hooks/tests/policy.test.sh"
mkdir -p "$SEL_WORLD/pi-extensions/pi-demo/tests" "$SEL_WORLD/docs"
printf 'run("tools/demo-tool")\n' >"$SEL_WORLD/pi-extensions/pi-demo/tests/demo.test.ts"
printf 'the `guards-scans` shard runs it\n' | tee "$SEL_WORLD/skills/AGENTS.md" >"$SEL_WORLD/docs/cite.md"
git -C "$SEL_WORLD" init -q
git -C "$SEL_WORLD" add -A

PRICE=skills/price-handling/scripts/x
PI=pi-extensions/pi-demo/src/x.ts
