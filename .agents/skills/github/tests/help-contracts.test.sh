#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$TEST_DIR/.." && pwd)"
REPO_ROOT="$(git -C "$TEST_DIR" rev-parse --show-toplevel)"
CANONICAL="$REPO_ROOT/skills/github"
MIRROR="$REPO_ROOT/.agents/skills/github"
[[ -d "$CANONICAL" ]] || CANONICAL="$PACKAGE_ROOT"
[[ -d "$MIRROR" ]] || MIRROR="$PACKAGE_ROOT"

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n        %s\n' "$1" "$2"
}

extract_section() {
  local output="$1" start="$2" end="$3" start_count end_count
  start_count=$(grep -cxF -- "$start" <<<"$output" || true)
  end_count=$(grep -cxF -- "$end" <<<"$output" || true)
  [[ "$start_count" -eq 1 && "$end_count" -eq 1 ]] || return 2
  awk -v start="$start" -v end="$end" '
    $0 == end {
      if (!seen_start) bad = 1
      else seen_end = 1
      exit
    }
    $0 == start { seen_start = 1; next }
    seen_start { print }
    END { if (bad || !seen_start || !seen_end) exit 2 }
  ' <<<"$output"
}

section_has_token() {
  local output="$1" start="$2" end="$3" token="$4" section
  section=$(extract_section "$output" "$start" "$end") || return 1
  grep -qF -- "$token" <<<"$section"
}

assert_section_token() {
  local output="$1" start="$2" end="$3" token="$4" name="$5"
  if section_has_token "$output" "$start" "$end" "$token"; then
    pass "$name"
  else
    fail "$name" "missing $token inside $start"
  fi
}

assert_section_rejects_decoy() {
  local output="$1" start="$2" end="$3" token="$4" name="$5"
  if section_has_token "$output" "$start" "$end" "$token"; then
    fail "$name" "accepted $token from a sibling section"
  else
    pass "$name"
  fi
}

assert_section_rejects_token() {
  local output="$1" start="$2" end="$3" token="$4" name="$5"
  if section_has_token "$output" "$start" "$end" "$token"; then
    fail "$name" "found stale token: $token"
  else
    pass "$name"
  fi
}

word_count_at_most() {
  local text="$1" limit="$2" count
  count=$(wc -w <<<"$text")
  [[ "$count" -le "$limit" ]]
}

assert_file_word_limit() {
  local file="$1" name="$2" text count
  text=$(<"$file")
  count=$(wc -w <<<"$text")
  if word_count_at_most "$text" 900; then
    pass "$name ($count words)"
  else
    fail "$name" "$count words exceeds 900"
  fi
}

assert_file_token() {
  local file="$1" token="$2" name="$3"
  if grep -qF -- "$token" "$file"; then
    pass "$name"
  else
    fail "$name" "missing token: $token"
  fi
}

run_help_contracts() {
  local label="$1" root="$2" github_help merge_help label_add_help label_remove_help pr_view_help sticky_help readme token
  github_help=$("$root/scripts/github.sh" --help)
  merge_help=$("$root/scripts/github.sh" pr-merge --help)
  label_add_help=$("$root/scripts/github.sh" label-add --help)
  label_remove_help=$("$root/scripts/github.sh" label-remove --help)
  pr_view_help=$("$root/scripts/github.sh" pr-view --help)
  sticky_help=$("$root/scripts/github.sh" sticky-comment --help)
  readme="$(<"$root/README.md")"

  for token in 'github.sh --help' '<command> --help' 'SKILL.md' 'DEVELOPMENT.md'; do
    assert_section_token "$readme" '# GitHub Queries' '## Setup' "$token" \
      "$label README entry point carries $token"
  done
  assert_section_rejects_token "$readme" '# GitHub Queries' '## Setup' \
    'SKILL.md` is the full command reference' \
    "$label README does not call SKILL.md the full reference"

  for token in 'Most subcommands' 'pr-view' 'gh pr view' '--format' \
    'sticky-comment' 'unrecognized flags' 'positional input' 'ignored'; do
    assert_section_token "$github_help" 'Argument rules:' 'Configuration:' "$token" \
      "$label argument rules carry $token"
  done

  for token in '--format' 'unrecognized flags' 'extra positionals' 'gh pr view'; do
    assert_section_token "$pr_view_help" 'Note:' 'Errors:' "$token" \
      "$label pr-view compatibility carries $token"
  done

  for token in 'Unrecognized flags' 'positional input' 'Surplus positionals' 'ignored'; do
    assert_section_token "$sticky_help" 'Compatibility:' 'Output (default):' "$token" \
      "$label sticky-comment compatibility carries $token"
  done

  for token in 'GH_TOKEN' 'GITHUB_TOKEN' 'GH_BOT_TOKEN' 'GH_BOT_USERNAME' \
    'GH_ISSUE_PATTERN' 'GH_VERIFY_CMD' 'KENDEX_GITHUB_OP_TIMEOUT' \
    'KENDEX_GITHUB_AUTH_TIMEOUT' 'KENDEX_GITHUB_PR_VIEW_TIMEOUT' \
    'KENDEX_GITHUB_GIT_HTTPS_FALLBACK' 'kendex.settings.toml' \
    '.kendex/settings.toml' '.env.local'; do
    assert_section_token "$github_help" 'Configuration:' 'Token selection:' "$token" \
      "$label configuration carries $token"
  done

  for token in 'GH_TOKEN, GH_BOT_TOKEN, GITHUB_TOKEN' 'op://' 'op read'; do
    assert_section_token "$github_help" 'Token selection:' 'Auth preflight:' "$token" \
      "$label token selection carries $token"
  done

  for token in 'gh api user' 'gh auth status'; do
    assert_section_token "$github_help" 'Auth preflight:' 'Errors and retries:' "$token" \
      "$label auth preflight carries $token"
  done

  for token in '{"error": "message"}' 'pr-view --json' 'gh_graphql' 'nonzero' \
    'GraphQL errors' 'gh_rest' 'rate limits' 'authentication' 'not-found' \
    '3 attempts' 'first attempt'; do
    assert_section_token "$github_help" 'Errors and retries:' 'Examples:' "$token" \
      "$label errors carry $token"
  done

  for token in 'kendex.settings.toml' '.kendex/settings.toml' '.env.local' \
    'Parent-process'; do
    assert_section_token "$label_add_help" 'Configuration:' 'Examples:' "$token" \
      "$label label-add configuration carries $token"
    assert_section_token "$label_remove_help" 'Configuration:' 'Examples:' "$token" \
      "$label label-remove configuration carries $token"
  done

  for token in 'ALREADY MERGED PR #N' 'QUEUED IN MERGE QUEUE PR #N' \
    'AUTO-MERGE ENABLED PR #N' 'BLOCKED PR #N' \
    'The requested operation failed' 'pre-existing queue entry' \
    'auto-merge request may remain active' 'CLOSED (not merged) PR #N'; do
    assert_section_token "$merge_help" 'Merge-mode exit codes:' '--check exit:' "$token" \
      "$label exit codes carry $token"
  done
  assert_section_rejects_token "$merge_help" 'Merge-mode exit codes:' '--check exit:' \
    'Nothing merged, queued, or armed.' \
    "$label BLOCKED outcome does not erase pre-existing pending state"

  for token in '--check exits 0' 'valid readiness JSON' 'can_merge=false' \
    'CLOSED' 'nonzero'; do
    assert_section_token "$merge_help" '--check exit:' 'Exit 75 is volatile:' "$token" \
      "$label check exit carries $token"
  done

  for token in 'merge-queue-watch' 'expected head' 'watch generation' \
    'durable verdict' 'recovery action' 'README.md "Exit 75 recovery"' \
    'github.sh pr-merge <N> --auto' 'await-mergeable'; do
    assert_section_token "$merge_help" 'Exit 75 is volatile:' 'Terminal and mutation rules:' "$token" \
      "$label exit-75 routing carries $token"
  done

  for token in 'github.sh router setup' 'MERGED or CLOSED' 'UNKNOWN continues' \
    'bot-token load' 'merge-state mutation' \
    'exact-head guarded' '--match-head-commit' '--delete-branch' \
    'best-effort'; do
    assert_section_token "$merge_help" 'Terminal and mutation rules:' 'Review-thread gate:' "$token" \
      "$label terminal and mutation rules carry $token"
  done

  for token in 'required_conversation_resolution' 'gh pr merge' 'UI Merge button'; do
    assert_section_token "$merge_help" 'Review-thread gate:' 'Force rules:' "$token" \
      "$label review-thread gate carries $token"
  done

  for token in '--force' '--auto' 'exact-head post-state'; do
    assert_section_token "$merge_help" 'Force rules:' '--check JSON:' "$token" \
      "$label force rules carry $token"
  done

  for token in 'can_merge' 'issues' 'transient' 'state' 'merged_at' 'head_runs' \
    'checks' 'ci-classify-refusal' 'unknown:' 'ci_pending:' 'ci_unconfigured:' \
    'ci_fetch_failed:' 'ci_failed:'; do
    assert_section_token "$merge_help" '--check JSON:' 'Examples:' "$token" \
      "$label check JSON carries $token"
  done
}

echo "=== bounded help contracts ==="
run_help_contracts canonical "$CANONICAL"
run_help_contracts mirror "$MIRROR"

echo
echo "=== section-boundary must-fail controls ==="
github_decoy=$'Argument rules:\nknown only\nConfiguration:\nunknown flags\nToken selection:'
assert_section_rejects_decoy "$github_decoy" 'Argument rules:' 'Configuration:' \
  'unknown flags' 'github token in a sibling section does not satisfy ownership'

reversed_decoy=$'Configuration:\nArgument rules:\nunknown flags\nToken selection:'
assert_section_rejects_decoy "$reversed_decoy" 'Argument rules:' 'Configuration:' \
  'unknown flags' 'end-before-start section boundaries are rejected'

merge_decoy=$'Exit 75 is volatile:\nwatch only\nTerminal and mutation rules:\nejected\nReview-thread gate:'
assert_section_rejects_decoy "$merge_decoy" 'Exit 75 is volatile:' \
  'Terminal and mutation rules:' 'ejected' \
  'pr-merge token in a sibling section does not satisfy ownership'

stale_blocked_help=$'Merge-mode exit codes:\n  1 BLOCKED PR #N\n  Nothing merged, queued, or armed.\n--check exit:'
if section_has_token "$stale_blocked_help" 'Merge-mode exit codes:' '--check exit:' \
    'Nothing merged, queued, or armed.'; then
  pass 'stale BLOCKED claim is detectable inside its owning section'
else
  fail 'stale BLOCKED claim is detectable inside its owning section' \
    'the stale-claim control did not reach the merge exit table'
fi

echo
echo "=== SKILL word ceiling and mirror ==="
assert_file_word_limit "$CANONICAL/SKILL.md" 'canonical SKILL stays within 900 words'
assert_file_word_limit "$MIRROR/SKILL.md" 'mirror SKILL stays within 900 words'
assert_file_token "$CANONICAL/SKILL.md" 'Do not hand-file' \
  'canonical SKILL keeps the report banner'
assert_file_token "$MIRROR/SKILL.md" 'Do not hand-file' \
  'mirror SKILL keeps the report banner'
assert_file_token "$CANONICAL/SKILL.md" '.agents/skills/orch/scripts/ci-wait' \
  'canonical SKILL routes CI waiting to orch'
assert_file_token "$MIRROR/SKILL.md" '.agents/skills/orch/scripts/ci-wait' \
  'mirror SKILL routes CI waiting to orch'
if cmp -s "$CANONICAL/SKILL.md" "$MIRROR/SKILL.md"; then
  pass 'canonical and mirror SKILL files are byte-equivalent'
else
  fail 'canonical and mirror SKILL files are byte-equivalent' 'cmp reported drift'
fi

over_limit=$(awk 'BEGIN { for (i = 1; i <= 901; i++) printf "word " }')
if word_count_at_most "$over_limit" 900; then
  fail '901-word control exceeds the ceiling' 'word limit accepted 901 words'
else
  pass '901-word control exceeds the ceiling'
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
