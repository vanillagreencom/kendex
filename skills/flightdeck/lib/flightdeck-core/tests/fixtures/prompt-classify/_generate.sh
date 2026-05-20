#!/usr/bin/env bash
# Generate the prompt-classify fixture corpus. One buffer + meta per tag.
# Run from this directory: ./_generate.sh
# Idempotent — overwrites existing files.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# Standard prompt-list footer present in most TUI prompts. Lets the post-
# footer matchers fire. Test cases that should NOT use the footer add their
# own --no-footer-gate via the meta file.
FOOTER='↑↓ to navigate · Enter to select · esc dismiss'

write() {
	local name="$1" tag="$2" content="$3" extra="${4:-}"
	printf '%s\n' "$content" > "$name.buffer"
	if [[ -n "$extra" ]]; then
		printf '%s\n' "$extra" >> "$name.buffer"
	fi
	printf '{ "expectedTag": "%s" }\n' "$tag" > "$name.meta.json"
}

write_nofooter() {
	local name="$1" tag="$2" content="$3"
	printf '%s\n' "$content" > "$name.buffer"
	printf '{ "expectedTag": "%s", "noFooterGate": true }\n' "$tag" > "$name.meta.json"
}

# Pre-footer rule (no footer gate involvement — matched before gate).
write 01-awaiting-direction awaiting-direction \
	"Master agent is standing by for further instructions
Awaiting user direction"

write 02-awaiting-direction-declined awaiting-direction \
	"User declined to answer questions."

# Footer gate misses → rendering / idle.
write 03-rendering rendering "Partial buffer with no footer yet."
write 04-idle idle "Some text here
❯ "

# Post-footer matchers (priority order).
write 10-bash-permission bash-permission-prompt \
	"Bash command requires permission to run

1. Allow once
2. Deny

$FOOTER"

write 11-terminal-state terminal-state-reached \
	"✅ MERGED PR #1234

Please end the session.

$FOOTER"

write 12-force-merge-confirm force-merge-confirm \
	"Mergeable status still UNKNOWN — Force merge anyway?

1. Yes, force merge
2. Wait

$FOOTER"

write 13-merge-ready-but-unknown merge-ready-but-unknown \
	"GitHub mergeable status still at UNKNOWN.

1. Continue waiting
2. Proceed anyway

$FOOTER"

write 14-merge-now merge-now \
	"PR #4321 is approved with CI passing. Merge it now?

1. Merge
2. Hold

$FOOTER"

write 15-bot-review-stuck bot-review-wait-stuck \
	"No bot review comments were found after 10 min.

1. Skip
2. Wait
3. Abort

$FOOTER"

write 16-rebase-multi-choice rebase-multi-choice \
	"This branch has merge conflicts with main.

How should I resolve the conflicts?

1. Rebase + force push
2. Manual resolution
3. Abort

$FOOTER"

write 17-force-push-prompt force-push-prompt \
	"Confirm force push to origin/feature-branch with --force-with-lease?

1. Force-push the change
2. Cancel

$FOOTER"

write 18-cleanup-prompt cleanup-prompt \
	"Cleanup the merged worktree at trees/cc-486?

1. Yes
2. No

$FOOTER"

write 19-audit-relation audit-relation-prompt \
	"ISSUE AUDIT complete — 3 follow-up issues identified.

Create these audit follow-up issues?

1. Yes, create all
2. Defer all

$FOOTER"

write 20-descope-related descope-related \
	"FIX RECONCILIATION suggests descoping CC-501 from CC-486.

1. Descope CC-501
2. Keep both

$FOOTER"

write 21-external-fix-suggestions external-fix-suggestions \
	"Apply the external review fix suggestions from gpt-5?

1. Apply all
2. Cherry-pick
3. Skip

$FOOTER"

write 22-cycle-fix-suggestions cycle-fix-suggestions \
	"Apply doc-wording fix from reviewer-doc?

1. Apply
2. Skip

$FOOTER"

write 23-multi-select-tabbed multi-select-tabbed \
	"Pick items:

← ☐ Option A → ☐ Option B → ☒ Option C →

$FOOTER"

write 24-generic-multi-choice generic-multi-choice \
	"What now?

1. Continue
2. Stop

$FOOTER"

# Edge — option list using `1)` delimiter (pi-style).
write 25-generic-parens generic-multi-choice \
	"Pick:

1) Yes
2) No

$FOOTER"

# A PR URL inside an interactive prompt is not a completion signal;
# the final-PR-URL sentinel is adapter/no-footer only.
write 26-generic-with-pr-url generic-multi-choice \
	"Review https://github.com/vanillagreencom/vstack/pull/172?

1. Wait
2. Stop

$FOOTER"

# Adapter-text path with --no-footer-gate. Same content, no TUI chrome.
write_nofooter 30-no-footer-merge-now merge-now \
	"PR #999 is approved with CI passing. Merge now?"

write_nofooter 31-no-footer-rebase rebase-multi-choice \
	"This PR has merge conflicts. How should I resolve the conflicts?"

# Adapter-text path with no detectable prompt → idle.
write_nofooter 32-no-footer-idle idle "All quiet."

# Pi/GitHub issue child contract: final non-empty line is the PR URL.
write_nofooter 33-no-footer-final-pr-url terminal-state-reached \
	"Implementation complete.

1. Tests pass
2. Branch pushed

https://github.com/vanillagreencom/vstack/pull/172"

echo "wrote $(ls -1 *.buffer | wc -l) fixtures"
