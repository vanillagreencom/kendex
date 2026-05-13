#!/usr/bin/env bash
# Classify a captured pane buffer into a flightdeck handler tag.
#
# Reads the buffer (from --buffer-file or stdin), runs sentinel matchers in
# specificity order, and prints the tag. If no terminator (footer or cursor)
# is present, returns `rendering` so the caller re-polls instead of acting
# on a partial buffer.
#
# Usage:
#   prompt-classify --buffer-file <path>
#   tmux capture-pane -t HT:cc-463.0 -p -S -200 | prompt-classify
#   prompt-classify --buffer-file /tmp/buf.txt --dry-run    # print tag + matched line
#
# Tags (in match-priority order):
#   rendering                  - prompt isn't fully painted yet
#   terminal-state-reached     - inner pane has signaled work-complete, end-the-session, or destroyed-cwd
#   bash-permission-prompt     - harness asking for explicit permission to run a bash command
#   force-merge-confirm        - "Force merge?" dialog after extended UNKNOWN
#   merge-ready-but-unknown    - "Mergeable status still UNKNOWN"
#   merge-now                  - "PR ... is approved with CI passing. Merge now?"
#   bot-review-wait-stuck      - bot-review-wait timeout with Skip/Wait/Abort options
#   rebase-multi-choice        - merge-conflict resolution prompt
#   force-push-prompt          - confirm force push (typically --force-with-lease over orphan/diverged remote)
#   stale-no-pr-branch         - per-issue agent asking to delete an unrelated local branch with no PR
#   stale-orphan-worktree      - per-issue agent asking to remove an unrelated worktree directory
#   cleanup-prompt             - worktree cleanup post-merge / on abort
#   audit-relation-prompt      - issue-audit creating new issues with structure column
#   descope-related            - reconciliation suggesting child-issue descope
#   external-fix-suggestions   - external/PR review fix-suggestion application
#   cycle-fix-suggestions      - in-cycle review fix-suggestion application
#   scope-creep-detected       - computed externally; classifier never returns this from buffer alone
#   multi-select-tabbed        - tabbed checkbox UI; needs --option-multi (NOT --option)
#   awaiting-direction         - recoverable post-cancel / no-prompt idle state
#   generic-multi-choice       - has option list but no specific match
#   idle                       - no prompt detected
#
# Exit code: 0 (always; tag goes to stdout)
set -euo pipefail

DRY_RUN=0
BUFFER_FILE=""
NO_FOOTER_GATE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --buffer-file) BUFFER_FILE="$2"; shift 2 ;;
    --buffer-file=*) BUFFER_FILE="${1#--buffer-file=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    # Skip the TUI-footer gate. Use this when the input is a structured
    # assistant-text blob from a harness adapter (HTTP /message, MCP
    # channel, WS events) — no rendered terminal chrome to look for.
    # Without this flag, classifier returns `rendering` for adapter
    # text since none of it ever has "Enter to select" / "↑↓ navigate"
    # footers.
    --no-footer-gate) NO_FOOTER_GATE=1; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "$BUFFER_FILE" ]]; then
  buf=$(<"$BUFFER_FILE")
else
  buf=$(cat)
fi

emit() {
  local tag="$1" matched="${2:-}"
  if [[ $DRY_RUN -eq 1 && -n "$matched" ]]; then
    printf '%s\t%s\n' "$tag" "$matched"
  else
    printf '%s\n' "$tag"
  fi
  exit 0
}

# awaiting-direction — recoverable post-cancel / post-decline state where
# the inner agent is alive but has no prompt to answer. Classified BEFORE
# the footer check because this state has no option-list footer; the
# default footer-gate would route it to idle and the daemon would never
# fire wake. Master synthesizes a continuation directive in handle-prompt.
if grep -qE 'Awaiting user (direction|input)|User declined to answer questions|standing by for further instructions|awaiting your response\b' <<< "$buf"; then
  emit awaiting-direction "post-cancel idle"
fi

# Terminator check — must see a known prompt-end before classifying.
# Common terminators across opencode, claude code, codex:
#   "Enter to select" / "↑↓ to navigate" / "esc dismiss" footers
#   Final "❯ " cursor on its own line at buffer end
#
# Adapter callers pass --no-footer-gate. The input is structured
# assistant text (HTTP /message extraction, channel JSONL, WS events)
# with no rendered terminal chrome — no footer is possible. The
# specific-shape matchers below handle the prompt detection on their
# own; the footer gate is only a buffer-completeness signal for the
# tmux-capture path.
if (( NO_FOOTER_GATE == 0 )); then
  if ! grep -qE '(Enter to (select|toggle|submit)|↑.*↓ (to )?navigate|esc.*dismiss|↑↓ select)' <<< "$buf"; then
    # No prompt footer detected. Could be idle or rendering.
    if grep -qE '(❯|>|■■■|⠋|⠙|⠸|⠴|⠦|⠧)\s*$' <<< "$buf"; then
      emit idle
    fi
    emit rendering
  fi
fi

# Specific-shape sentinels in priority order. Most specific first.

# bash-permission-prompt — harness asking for permission to run a bash command.
# Most common when --dangerously-skip-permissions (or equivalent) is NOT set on
# the inner agent. Sentinels match common harness phrasings.
if grep -qE 'Bash command requires permission|Allow command\?|Run this command\?|requires permission to run' <<< "$buf"; then
  emit bash-permission-prompt "permission prompt"
fi

# terminal-state-reached — work complete, session over, no further prompts coming.
# Portable signals (any harness):
#   - explicit "MERGED" / "session complete" / "end the session" / "Please end the session"
#   - destroyed-CWD pattern indicating worktree was removed mid-session
# Harness-specific signals are evaluated by the close-issue workflow with the
# pane's harness adapter; the classifier surfaces the tag on the portable
# signal alone, and the handler does the multi-signal verification.
if grep -qE '(✅|\bMERGED\b).*PR ?#?[0-9]+|Please end the session|session complete|SESSION CWD DESTROYED|Path does not exist.*tree|Shutting down team\.|\[✓\]\s*§\s*5\s*Finalize session|Finalize session\b.*✓|Finalize session\b.*\bdone\b' <<< "$buf"; then
  emit terminal-state-reached "session-end signal"
fi

# force-merge after sustained UNKNOWN
if grep -qE 'Mergeable status still UNKNOWN.*Force merge|UNKNOWN.* Force merge' <<< "$buf"; then
  emit force-merge-confirm "force-merge dialog"
fi

# merge-ready-but-unknown (initial UNKNOWN report, before extended wait)
if grep -qE 'Mergeable status (stuck|still) UNKNOWN|GitHub mergeable status (stuck|still) at UNKNOWN' <<< "$buf"; then
  emit merge-ready-but-unknown "UNKNOWN-state notice"
fi

# merge-now offer. Broadened (Run 4): orchestration sometimes prompts with
# the bare "Merge PR #N now?" form, and opencode sometimes wraps the line
# differently. Match the "merge ... now" intent rather than the exact
# preamble — gated by the option-list footer above so banners don't trip.
if grep -qE 'is approved.*CI passing.*Merge( it)? now|approved with CI passing.*Merge now|Merge( the)? PR #?[0-9]+ now\??|Merge now\??' <<< "$buf"; then
  emit merge-now "merge-ready confirmation"
fi

# bot-review-wait stuck. Broadened (Run 4): opencode renders the prompt
# with Skip/Wait/Abort options on a stuck bot review.
if grep -qE 'No bot review comments were found|Bot review hasn.t started|bot review verdict.*pending|bot[- ]review[- ]wait.*(stuck|stalled|timed out)|Skip.*Wait.*Abort' <<< "$buf"; then
  emit bot-review-wait-stuck "bot-review timeout"
fi

# rebase-multi-choice
if grep -qE 'merge conflicts|How should I resolve.*conflicts|Rebase \+ force push' <<< "$buf"; then
  emit rebase-multi-choice "rebase-conflict prompt"
fi

# force-push-prompt — confirm a force push (typically --force-with-lease over
# an orphan/diverged remote ref). Distinct from rebase-multi-choice which is
# about resolving merge conflicts. Sentinels match common phrasings.
if grep -qE 'Force[- ]push (to|over|the)|--force-with-lease|push.*\?.*force|Confirm force push' <<< "$buf"; then
  emit force-push-prompt "force-push confirmation"
fi

# stale-no-pr-branch — per-issue agent surfacing a sweep prompt for an
# unrelated local branch that has no associated PR. This violates the
# Flightdeck cleanup-scope rule (see merge-pr.md § 5 / issue #18).
# Master answers Keep regardless of buffer content; the bug is upstream.
# Match BEFORE cleanup-prompt so the more specific tag wins.
if grep -qE 'Local branch [^ ]+ has no associated PR\. Delete' <<< "$buf"; then
  emit stale-no-pr-branch "stale no-PR branch prompt"
fi

# stale-orphan-worktree — per-issue agent surfacing a sweep prompt for
# an unrelated orphan worktree directory or a sibling's stale worktree.
# Same scope violation. Match BEFORE cleanup-prompt so the more specific
# tag wins.
if grep -qE 'Stale worktree for [^ ]+ \(PR already merged\)\. Remove|^orphan: ' <<< "$buf"; then
  emit stale-orphan-worktree "stale orphan worktree prompt"
fi

# cleanup-prompt (post-merge or on-abort worktree removal)
if grep -qE 'Cleanup the .* worktree|Worktree for .* exists\. Cleanup|Remove (these .* )?worktree' <<< "$buf"; then
  emit cleanup-prompt "worktree-cleanup prompt"
fi

# audit-relation-prompt (issue audit creating new issues; also post-creation
# delegate-or-defer prompts asking what to do with newly-created children)
if grep -qE 'Create (these )?audit(ed)? (follow-up )?issues|ISSUE AUDIT|Issue Audit\b|TPM audit complete|delegate (now )?or defer|Delegate all|Defer all' <<< "$buf"; then
  emit audit-relation-prompt "issue-audit creation"
fi

# descope-related
if grep -qE 'Descope CC?-?[A-Z0-9-]+|FIX RECONCILIATION' <<< "$buf"; then
  emit descope-related "descope reconciliation"
fi

# external-fix-suggestions (post-cycle external review)
# Matches: "Apply the external review fix suggestions?", "Apply external review fixes",
# and variants like "Apply <topic> fix from <external-reviewer>?".
if grep -qE 'Apply (the )?external[- ]?review|external[- ]?review (fix|suggestion)|Apply\s+[A-Za-z0-9 \-]{1,40}\s+(fix|suggestion)s?\s+from\s+(external|second-opinion|gemini|gpt|codex)' <<< "$buf"; then
  emit external-fix-suggestions "external-review fixes"
fi

# cycle-fix-suggestions
# Matches: canonical "Apply fix suggestions?", "Apply fixes?", and topical
# variants like "Apply doc-wording fix from reviewer-doc?" or
# "Apply <topic> fix from <reviewer-name>?".
if grep -qE 'Apply (the )?fix suggestions|Apply fixes\?|Apply\s+[A-Za-z0-9 \-]{1,40}\s+(fix|suggestion)s?\s+from\s+reviewer[- ]' <<< "$buf"; then
  emit cycle-fix-suggestions "cycle-review fixes"
fi

# Multi-select with tab navigation (claude code's checkbox-tab UI). The
# arrow-tab pair `←` / `→` plus a checkbox glyph (☐/☒/✔/✓) marks this as
# the shape that needs --option-multi (per-item Space toggle), NOT
# --option N (which would mis-toggle items along the path). Match before
# generic-multi-choice so the more specific tag wins.
if grep -qE '(←|→).*(☐|☒|✔|✓)|(☐|☒|✔|✓).*(←|→)' <<< "$buf"; then
  emit multi-select-tabbed "tabbed checkbox select"
fi

# Generic option-list shape (numbered options). Accepts both `1.` and
# `1)` delimiters — different harnesses use different conventions
# (claude/opencode tend toward `1.`, pi tends toward `1)`).
if grep -qE '^\s*[1-9][.)] ' <<< "$buf"; then
  emit generic-multi-choice "unmatched option list"
fi

emit idle
