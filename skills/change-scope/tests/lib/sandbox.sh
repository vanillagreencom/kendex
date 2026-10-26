#!/usr/bin/env bash
# Shared scaffolding for the change-scope suites and the harness-ci suites
# that judge its CI wrapper: a disposable git sandbox, the paths to the
# scripts under test, a planted install layout of both packages, and the
# assertions every suite makes.
#
# Sourced, never run. It sets the strict mode it needs rather than trusting the
# sourcing suite to have set it, which is also what every suite here sets.
set -euo pipefail

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GITHUB_OUTPUT HARNESS_CI_LOCK_KENDEX HARNESS_CI_QUEUE_PATHS HARNESS_CI_QUEUE_SELECTOR

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
SANDBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The two packages: this one, and the harness-ci wrapper beside it. The
# scripts come from the catalog whichever package's suite sources this file.
CHANGE_SCOPE_PACKAGE="$(cd "$SANDBOX_LIB_DIR/../.." && pwd)"
HARNESS_CI_PACKAGE="$(cd "$CHANGE_SCOPE_PACKAGE/../harness-ci" && pwd)"
HARNESS_ONLY="${HARNESS_ONLY_UNDER_TEST:-$CHANGE_SCOPE_PACKAGE/scripts/harness-only}"
CHANGE_SCOPE="${CHANGE_SCOPE_UNDER_TEST:-$CHANGE_SCOPE_PACKAGE/scripts/change-scope}"
CHANGE_CLASS="${CHANGE_CLASS_UNDER_TEST:-$HARNESS_CI_PACKAGE/scripts/change-class}"

PASS=0
FAIL=0

# Checked on the spot: a failed mktemp leaves the variable empty, and an empty
# SANDBOX would send the cleanup trap at the filesystem root.
SANDBOX="$(mktemp -d -t change-scope-XXXXXX)" || SANDBOX=""
if [ -z "$SANDBOX" ] || [ ! -d "$SANDBOX" ]; then
  echo "change-scope tests: could not create a sandbox directory" >&2
  exit 1
fi
cleanup() { rm -rf "$SANDBOX" 2>/dev/null || true; }
trap cleanup EXIT

write_inventory() { # REPO
  # Fixture writer output. Product paths remain absent even inside a harness.
  printf '%s\n' '[".kendex-generated.json",".agents/skills/orch/SKILL.md",".agents/skills/orch/app.ts",".agents/skills/orch/renamed.ts",".agents/skills/review-gate/scripts/lib/settings.sh",".claude/agents/rust.md",".codex/agents/rust.md",".opencode/agent/rust.md",".cursor/rules/rust.mdc",".pi/kendex/hooks/guard.ts",".pi/settings.json","opencode.json","opencode.jsonc",".gemini/settings.json",".github/agents/rust.agent.md","CLAUDE.md","runtime/agent.conf"]' >"$1/.kendex-generated.json"
}

# Fixture repositories carry their own identity and default branch so the
# suite reads the same on a runner with no global git config.
new_repo() { # NAME -> prints the repo path
  local repo="$SANDBOX/$1"
  mkdir -p "$repo" || return
  git -C "$repo" init -q -b main || return
  git -C "$repo" config gc.auto 0 || return
  git -C "$repo" config maintenance.auto false || return
  git -C "$repo" config user.email change-scope@example.invalid || return
  git -C "$repo" config user.name "change-scope tests" || return
  write_inventory "$repo" || return
  printf '%s' "$repo"
}

# One commit per call: write every path, then record them together.
commit_paths() { # REPO MESSAGE PATH...
  local repo="$1" message="$2" path
  shift 2
  for path in "$@"; do
    mkdir -p "$repo/$(dirname "$path")"
    printf 'content for %s\n' "$path" >>"$repo/$path"
  done
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$message"
}

# The verdict line alone. stderr is dropped here on purpose: these assertions
# are about what a caller reads from stdout.
classify() { # ARGS... -> the harness_only= line
  "$HARNESS_ONLY" "$@" 2>/dev/null
}

# The globs of the boundary group of this package's narrow-change.conf, which
# the narrow-boundary and queue-only suites both read: the `path` lines after
# its `# [boundary]` line, up to the first blank line.
boundary_globs() { # CONF
  awk '/^# \[boundary\]/ { group = 1; next } group && /^$/ { exit } group && /^path / { print substr($0, 6) }' "$1"
}

assert_eq() { # LABEL EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then
    printf '  PASS: %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3" >&2
    FAIL=$((FAIL + 1))
  fi
}

require_rows() { # TABLE COUNT
  if [ "$2" -eq 0 ]; then
    printf 'FAIL: %s table executed no rows\n' "$1" >&2
    exit 1
  fi
}

assert_verdict() { # LABEL true|false ARGS...
  local label="$1" expected="$2" out status
  shift 2
  if out="$(classify "$@")"; then
    status=0
  else
    status=$?
  fi
  assert_eq "$label" "harness_only=$expected exit 0" "$out exit $status"
}

assert_docs_verdict() { # LABEL true|false ARGS...
  local label="$1" expected="$2" out status
  shift 2
  if out="$(classify --mode docs "$@")"; then
    status=0
  else
    status=$?
  fi
  assert_eq "$label" "docs_only=$expected exit 0" "$out exit $status"
}

# The classifier's stdout for ARGS, held to EXPECTED. CHANGE_SCOPE names the
# classifier a row runs, so a control sets it to a planted copy.
assert_class() { # LABEL EXPECTED ARGS...
  local label="$1" expected="$2" out status
  shift 2
  if out="$("$CHANGE_SCOPE" "$@" 2>/dev/null)"; then
    status=0
  else
    status=$?
  fi
  assert_eq "$label" "change_class=$expected exit 0" "$out exit $status"
}

# An installed package layout under ROOT: change-scope's scripts and
# references and harness-ci's scripts, copied, so a script standing there
# resolves the same siblings the shipped one does. The sibling bot-instructions
# package is linked only where a case asks (`bot-instructions`): the render
# proof hands it to the verifier. A case that needs a mutant writes its own
# body over a path under the layout this prints.
plant_layout() { # ROOT [bot-instructions] -> prints ROOT
  mkdir -p "$1/change-scope" "$1/harness-ci"
  cp -R "$CHANGE_SCOPE_PACKAGE/scripts" "$1/change-scope/scripts"
  cp -R "$CHANGE_SCOPE_PACKAGE/references" "$1/change-scope/references"
  cp -R "$HARNESS_CI_PACKAGE/scripts" "$1/harness-ci/scripts"
  [ "${2:-}" != bot-instructions ] ||
    ln -s "$(cd "$CHANGE_SCOPE_PACKAGE/../bot-instructions" && pwd)" "$1/bot-instructions"
  chmod +x "$1/change-scope/scripts/"* "$1/harness-ci/scripts/"*
  printf '%s' "$1"
}

# Where a script under test lives: change-scope's scripts/ for the classifier,
# its reader and its libraries, harness-ci's for the wrapper and its lane
# libraries. The two packages share no script name but the reader, whose
# harness-ci copy is a forwarder no control edits.
script_package() { # SCRIPT -> change-scope|harness-ci
  case "$1" in
    change-scope | harness-only | lib/change-scope.sh | lib/branch-growth.sh | lib/kendex-env.sh)
      printf change-scope ;;
    *) printf harness-ci ;;
  esac
}

# The entry point a planted layout is run through: the classifier for this
# package's suites, the wrapper for harness-ci's, which set PLANT_ENTRY after
# sourcing this file.
PLANT_ENTRY=change-scope
plant_entry_path() { # ROOT -> the planted entry's path
  case "$PLANT_ENTRY" in
    change-scope) printf '%s/change-scope/scripts/change-scope' "$1" ;;
    change-class) printf '%s/harness-ci/scripts/change-class' "$1" ;;
    *) echo "sandbox: unknown PLANT_ENTRY $PLANT_ENTRY" >&2; exit 1 ;;
  esac
}

# A layout with SCRIPT swapped for a planted copy.
plant() { # ROOT SCRIPT PLANTED -> prints the planted entry's path
  plant_layout "$1" bot-instructions >/dev/null
  cp "$3" "$1/$(script_package "$2")/scripts/$2"
  chmod +x "$1/$(script_package "$2")/scripts/$2"
  plant_entry_path "$1"
}

# A copy of the package's SCRIPT with each exact LINE replaced by
# REPLACEMENT, `-` deleting it, planted beside the real scripts. Each LINE
# has to occur exactly once in the copy, or the control is not an edit.
mutant() { # NAME SCRIPT LINE REPLACEMENT [LINE REPLACEMENT]...
  local name="$1" script="$2" copy package
  shift 2
  package="$(script_package "$script")"
  copy="$SANDBOX/$name.${script##*/}"
  cp "$CHANGE_SCOPE_PACKAGE/../$package/scripts/$script" "$copy"
  while [ "$#" -ge 2 ]; do
    if ! LINE="$1" WITH="$2" awk '
      $0 == ENVIRON["LINE"] { hits++; if (ENVIRON["WITH"] != "-") print ENVIRON["WITH"]; next }
      { print }
      END { exit hits == 1 ? 0 : 3 }
    ' "$copy" >"$copy.next"; then
      echo "FAIL: control $name: '$1' does not occur once in $script" >&2
      exit 1
    fi
    mv "$copy.next" "$copy"
    shift 2
  done
  plant "$SANDBOX/$name" "$script" "$copy"
}

report() { # SUITE
  printf '%s: %d passed, %d failed\n' "$1" "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}
