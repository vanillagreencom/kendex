#!/bin/bash
# Get sticky/review-summary bot comment from a PR.
# Usage: ./sticky-comment.sh <PR#> [--body|--updated-at|--verdict|--analysis] [--bot <login>]
#
# By default this targets the bot in $GH_BOT_USERNAME (Claude-style sticky),
# or falls back to a known review-bot Claude-style review-summary comment when
# no bot is configured. Pass --bot to query a different reviewer — useful when
# multiple review bots (e.g. Claude + Codex) are configured for a single PR.
#
# Returns JSON by default, or specific field with flags:
#   --body         Just the comment body
#   --updated-at   Just the updated_at timestamp
#   --verdict      "approved" | "changes" | "pending" (formal review > sticky text)
#   --analysis     Deep analysis: recommendation, remaining items, merge readiness
#   --bot <login>  Override $GH_BOT_USERNAME for this call
#
# Exit codes:
#   0 - Success
#   1 - Usage error or no sticky comment found

set -euo pipefail

_SC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SC_DIR/../lib/github-api.sh"

show_help() {
    cat << 'EOF'
Get Bot Sticky / Review Summary Comment

Usage: sticky-comment.sh <PR#> [options]

Arguments:
  PR#              PR number (required)

Options:
  --body           Just the comment body
  --updated-at     Just the updated_at timestamp
  --verdict        "approved" | "changes" | "pending" (formal review > sticky text)
  --analysis       Deep analysis: recommendation, remaining items, merge readiness
  --bot <login>    Override $GH_BOT_USERNAME for this call (e.g. for Codex)
  --help, -h       Show this help

Output (default):
  JSON object with body, updated_at, id, and computed verdict

Analysis Output:
  {
    "recommendation": "approve" | "changes" | "block" | "pending",
    "remaining_item": "issue title if any",
    "can_merge": true | false
  }

Examples:
  sticky-comment.sh 23                              # Full JSON for configured/default bot; auto-detects known Claude-style if unset
  sticky-comment.sh 23 --body                       # Just comment body
  sticky-comment.sh 23 --verdict --bot 'codex[bot]' # Codex's verdict
EOF
}

PR_NUM=""
FLAG=""
BOT_OVERRIDE=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            show_help
            exit 0
            ;;
        --bot)
            BOT_OVERRIDE="$2"
            shift 2
            ;;
        --bot=*)
            BOT_OVERRIDE="${1#--bot=}"
            shift
            ;;
        --body|--updated-at|--verdict|--analysis)
            FLAG="$1"
            shift
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done
PR_NUM="${POSITIONAL[0]:-}"
# Accept legacy positional flag form: sticky-comment.sh 23 --verdict
if [[ -z "$FLAG" && "${POSITIONAL[1]:-}" =~ ^--(body|updated-at|verdict|analysis)$ ]]; then
    FLAG="${POSITIONAL[1]}"
fi

BOT_USER="${BOT_OVERRIDE:-${GH_BOT_USERNAME:-review-bot[bot]}}"
BOT_EXPLICIT=false
if [[ -n "$BOT_OVERRIDE" || -n "${GH_BOT_USERNAME:-}" ]]; then
  BOT_EXPLICIT=true
fi

if [[ -z "$PR_NUM" ]]; then
  echo '{"error": "Usage: sticky-comment.sh <PR#> [--body|--updated-at|--verdict|--analysis]"}' >&2
  exit 1
fi

# Fetch comments with error handling
RESPONSE=$(gh api "repos/{owner}/{repo}/issues/$PR_NUM/comments" 2>&1) || {
  ERROR_MSG=$(echo "$RESPONSE" | tr '\n' ' ' | head -c 100)
  jq -n --arg msg "API failed: $ERROR_MSG" '{error: $msg}' >&2
  exit 1
}

# Check for API error response (has "message" field but no array)
if echo "$RESPONSE" | jq -e '.message' >/dev/null 2>&1; then
  echo "{\"error\": \"$(echo "$RESPONSE" | jq -r '.message')\"}" >&2
  exit 1
fi

find_sticky_comment() {
  local response="$1"
  local allow_any="false"
  if [[ "$BOT_EXPLICIT" == "false" ]]; then
    allow_any="true"
  fi
  select_sticky_comment_from_comments "$response" "$BOT_USER" "$allow_any"
}

# Find sticky comment: prefer the configured/default bot, then (when no bot was
# explicitly configured) fall back to a known review-bot Claude-style review
# summary such as `**Claude finished ...** —— [View job](...)`.
STICKY=$(find_sticky_comment "$RESPONSE")

# Validate we got a comment object (has id and body)
# Retry once after brief delay if not found (handles API sync delay)
if [[ -z "$STICKY" || "$STICKY" == "null" ]] || ! echo "$STICKY" | jq -e '.id and .body' >/dev/null 2>&1; then
  sleep 2
  RESPONSE=$(gh api "repos/{owner}/{repo}/issues/$PR_NUM/comments" 2>&1) || true
  STICKY=$(find_sticky_comment "$RESPONSE")

  if [[ -z "$STICKY" || "$STICKY" == "null" ]] || ! echo "$STICKY" | jq -e '.id and .body' >/dev/null 2>&1; then
    echo '{"error": "No sticky comment found"}' >&2
    exit 1
  fi
fi

# Helper: detect verdict from body text. Delegates to github-api.sh so
# sticky-comment and pr-review-status share one parser.
get_verdict() {
  local body="$1"
  compute_sticky_verdict_from_body "$body"
}

# Helper: deep analysis of bot recommendation
# Parses multiple patterns from bot comments
get_analysis() {
  local body="$1"
  local rec_type="pending"

  # Pattern 1: Explicit "### Recommendation" section
  local rec_section
  rec_section=$(echo "$body" | grep -A5 -i "### Recommendation\|Recommendation:" | head -6 || true)

  # Pattern 2: "Status:" or "Verdict:" lines
  local status_line
  status_line=$(echo "$body" | grep -i "Status:\|Verdict:" | head -2 || true)

  # Pattern 3: Direct approval statements in body
  local approval_statement
  approval_statement=$(echo "$body" | grep -iE "✅.*approved|\*\*Approved\*\*|is \*\*approved\*\*|approved for merge|ready for merge|Review Complete ✅" | head -2 || true)

  # Combine all sources for analysis
  local all_signals="$rec_section $status_line $approval_statement"

  # Determine recommendation type (order matters: most specific first)
  if echo "$all_signals" | grep -qi "approve with follow-up\|approve.*follow-up"; then
    rec_type="approve_with_followup"
  elif echo "$all_signals" | grep -qiE "✅.*[Aa]pproved|\*\*[Aa]pproved\*\*|approved for merge|ready for merge|Verdict.*Approved"; then
    rec_type="approve"
  elif echo "$all_signals" | grep -qiE "will block|blocks merge|cannot merge|do not merge|reject"; then
    # Note: avoid matching "no blocking issues" which is positive
    rec_type="block"
  elif echo "$all_signals" | grep -qi "changes requested\|address.*before\|needs changes"; then
    rec_type="changes"
  elif echo "$all_signals" | grep -qi "Review Complete ✅"; then
    # "Review Complete ✅" without explicit rejection = approve
    rec_type="approve"
  fi

  # Extract remaining items (under "### Remaining Issue" or similar)
  local remaining_section remaining_title
  remaining_section=$(echo "$body" | sed -n '/### Remaining Issue/,/###/p' | head -20 || true)
  if [[ -n "$remaining_section" ]]; then
    # Get the bolded title (first **text** pattern) - macOS compatible
    remaining_title=$(echo "$remaining_section" | sed -n 's/.*\*\*\([^*]*\)\*\*.*/\1/p' | head -1 || true)
  else
    remaining_title=""
  fi

  # Determine if merge-ready (approve or approve_with_followup)
  local can_merge="false"
  if [[ "$rec_type" == "approve" || "$rec_type" == "approve_with_followup" ]]; then
    can_merge="true"
  fi

  # Output JSON
  jq -n \
    --arg rec "$rec_type" \
    --arg remaining "$remaining_title" \
    --argjson can_merge "$can_merge" \
    '{recommendation: $rec, remaining_item: $remaining, can_merge: $can_merge}'
}

case "$FLAG" in
  --body)
    echo "$STICKY" | jq -r '.body'
    ;;
  --updated-at)
    echo "$STICKY" | jq -r '.updated_at'
    ;;
  --verdict)
    # Primary: formal GitHub review state (structured, reliable)
    STICKY_BOT_USER=$(echo "$STICKY" | jq -r '.user.login // empty')
    FORMAL=$(get_formal_review_verdict "$PR_NUM" "${STICKY_BOT_USER:-$BOT_USER}")
    if [[ -n "$FORMAL" ]]; then
      echo "$FORMAL"
    else
      # Fallback: sticky comment text parsing
      BODY=$(echo "$STICKY" | jq -r '.body')
      get_verdict "$BODY"
    fi
    ;;
  --analysis)
    BODY=$(echo "$STICKY" | jq -r '.body')
    get_analysis "$BODY"
    ;;
  *)
    # Return full JSON with computed verdict
    # Primary: formal review; fallback: sticky text parsing
    BODY=$(echo "$STICKY" | jq -r '.body')
    STICKY_BOT_USER=$(echo "$STICKY" | jq -r '.user.login // empty')
    FORMAL=$(get_formal_review_verdict "$PR_NUM" "${STICKY_BOT_USER:-$BOT_USER}")
    VERDICT="${FORMAL:-$(get_verdict "$BODY")}"
    # Sanitize control characters in body to prevent jq parse errors
    echo "$STICKY" | jq --arg v "$VERDICT" '.body |= gsub("[[:cntrl:]]"; "") | . + {verdict: $v}'
    ;;
esac
