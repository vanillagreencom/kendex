#!/usr/bin/env bash
# Shared scaffolding for the harness-ci suites: a disposable git sandbox, the
# path to the script under test, and the two assertions every suite makes.
#
# Sourced, never run. It sets the strict mode it needs rather than trusting the
# sourcing suite to have set it, which is also what every suite here sets.
set -euo pipefail

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GITHUB_OUTPUT HARNESS_CI_LOCK_KENDEX

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
HARNESS_ONLY="${HARNESS_ONLY_UNDER_TEST:-$(cd "$TEST_DIR/../scripts" && pwd)/harness-only}"
CHANGE_CLASS="${CHANGE_CLASS_UNDER_TEST:-$(cd "$TEST_DIR/../scripts" && pwd)/change-class}"

PASS=0
FAIL=0

# Checked on the spot: a failed mktemp leaves the variable empty, and an empty
# SANDBOX would send the cleanup trap at the filesystem root.
SANDBOX="$(mktemp -d -t harness-ci-XXXXXX)" || SANDBOX=""
if [ -z "$SANDBOX" ] || [ ! -d "$SANDBOX" ]; then
  echo "harness-ci tests: could not create a sandbox directory" >&2
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
  git -C "$repo" config user.email harness-ci@example.invalid || return
  git -C "$repo" config user.name "harness-ci tests" || return
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

# The globs of the boundary group of orch's narrow-change.conf, which the
# narrow-boundary and narrow-change suites both read: the `path` lines after
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

assert_class() { # LABEL EXPECTED ARGS...
  local label="$1" expected="$2" out status
  shift 2
  if out="$("$CHANGE_CLASS" "$@" 2>/dev/null)"; then
    status=0
  else
    status=$?
  fi
  assert_eq "$label" "change_class=$expected exit 0" "$out exit $status"
}

# The orch package beside harness-ci, which the measured classes source. A
# suite that never plants a package runs where it is absent.
ORCH_PACKAGE="$(cd "$(dirname "$CHANGE_CLASS")/../.." && pwd)/orch"

# A package laid out as the real one, with the script under test swapped for
# a planted copy.
plant() { # ROOT SCRIPT PLANTED -> prints the planted change-class path
  mkdir -p "$1/harness-ci/scripts"
  cp "$(dirname "$CHANGE_CLASS")/harness-only" "$(dirname "$CHANGE_CLASS")/change-class" \
    "$1/harness-ci/scripts/"
  ln -s "$ORCH_PACKAGE" "$1/orch"
  cp "$3" "$1/harness-ci/scripts/$2"
  chmod +x "$1/harness-ci/scripts/"*
  printf '%s' "$1/harness-ci/scripts/change-class"
}

# A copy of the package's SCRIPT with each exact LINE replaced by
# REPLACEMENT, `-` deleting it, planted beside the real scripts. Each LINE
# has to occur exactly once in the copy, or the control is not an edit.
mutant() { # NAME SCRIPT LINE REPLACEMENT [LINE REPLACEMENT]...
  local name="$1" script="$2" copy
  shift 2
  copy="$SANDBOX/$name.$script"
  cp "$(dirname "$CHANGE_CLASS")/$script" "$copy"
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
