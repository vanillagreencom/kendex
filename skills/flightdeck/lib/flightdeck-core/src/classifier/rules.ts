// Sentinel regex rules for prompt-classify, in priority order.
// Mirrors scripts/prompt-classify (bash) exactly — any divergence is a bug.
// Each rule emits a tag when its pattern matches the captured buffer.
// Order matters: more-specific shapes are listed before more-general ones,
// and the first match wins.

export interface Rule {
	tag: string;
	pattern: RegExp;
	matched: string;
}

// Tags that assume issue/worktree/PR context. When prompt-classify is told
// it is classifying a non-issue TrackedEntry, these are rewritten to
// `domain-mismatch` so the watch loop can warn/escalate instead of taking
// destructive issue-mode action against an ad-hoc pane.
export const ISSUE_ONLY_TAGS = new Set<string>([
	"force-merge-confirm",
	"merge-ready-but-unknown",
	"merge-now",
	"bot-review-wait-stuck",
	"rebase-multi-choice",
	"force-push-prompt",
	"stale-no-pr-branch",
	"stale-orphan-worktree",
	"cleanup-prompt",
	"audit-relation-prompt",
	"descope-related",
	"external-fix-suggestions",
	"cycle-fix-suggestions",
	"scope-creep-detected",
	"multi-select-tabbed",
]);

// Awaiting-direction is classified before the footer gate (post-cancel
// idle state has no option-list footer).
export const PRE_FOOTER_RULES: Rule[] = [
	{
		tag: "awaiting-direction",
		matched: "post-cancel idle",
		pattern: /Awaiting user (direction|input)|User declined to answer questions|standing by for further instructions|awaiting your response\b/,
	},
];

// Footer-gate detection. When the gate is enabled (default), the buffer
// must contain one of these terminators or the classifier returns
// `rendering` (still painting) or `idle` (cursor present, no prompt).
export const FOOTER_GATE = /(Enter to (select|toggle|submit)|↑.*↓ (to )?navigate|esc.*dismiss|↑↓ select)/;
export const IDLE_CURSOR = /(❯|>|■■■|⠋|⠙|⠸|⠴|⠦|⠧)\s*$/m;

// Post-footer sentinel matchers in priority order.
export const POST_FOOTER_RULES: Rule[] = [
	{
		tag: "bash-permission-prompt",
		matched: "permission prompt",
		pattern: /Bash command requires permission|Allow command\?|Run this command\?|requires permission to run/,
	},
	{
		tag: "terminal-state-reached",
		matched: "session-end signal",
		pattern: /(✅|\bMERGED\b).*PR ?#?[0-9]+|Please end the session|session complete|SESSION CWD DESTROYED|Path does not exist.*tree|Shutting down team\.|\[✓\]\s*§\s*5\s*Finalize session|Finalize session\b.*✓|Finalize session\b.*\bdone\b/,
	},
	{
		tag: "force-merge-confirm",
		matched: "force-merge dialog",
		pattern: /Mergeable status still UNKNOWN.*Force merge|UNKNOWN.* Force merge/,
	},
	{
		tag: "merge-ready-but-unknown",
		matched: "UNKNOWN-state notice",
		pattern: /Mergeable status (stuck|still) UNKNOWN|GitHub mergeable status (stuck|still) at UNKNOWN/,
	},
	{
		tag: "merge-now",
		matched: "merge-ready confirmation",
		pattern: /is approved.*CI passing.*Merge( it)? now|approved with CI passing.*Merge now|Merge( the)? PR #?[0-9]+ now\??|Merge now\??/,
	},
	{
		tag: "bot-review-wait-stuck",
		matched: "bot-review timeout",
		pattern: /No bot review comments were found|Bot review hasn.t started|bot review verdict.*pending|bot[- ]review[- ]wait.*(stuck|stalled|timed out)|Skip.*Wait.*Abort/,
	},
	{
		tag: "rebase-multi-choice",
		matched: "rebase-conflict prompt",
		pattern: /merge conflicts|How should I resolve.*conflicts|Rebase \+ force push/,
	},
	{
		tag: "force-push-prompt",
		matched: "force-push confirmation",
		pattern: /Force[- ]push (to|over|the)|--force-with-lease|push.*\?.*force|Confirm force push/,
	},
	// Defensive coverage for Flightdeck-scope violations from older
	// orchestration builds (issue #18). Master answers Keep on these tags
	// regardless of buffer detail. Order matters — must match before
	// cleanup-prompt so the more specific tag wins.
	{
		tag: "stale-no-pr-branch",
		matched: "stale no-PR branch prompt",
		pattern: /Local branch [^ ]+ has no associated PR\. Delete/,
	},
	{
		tag: "stale-orphan-worktree",
		matched: "stale orphan worktree prompt",
		pattern: /Stale worktree for [^ ]+ \(PR already merged\)\. Remove|^orphan: /m,
	},
	{
		tag: "cleanup-prompt",
		matched: "worktree-cleanup prompt",
		pattern: /Cleanup the .* worktree|Worktree for .* exists\. Cleanup|Remove (these .* )?worktree/,
	},
	{
		tag: "audit-relation-prompt",
		matched: "issue-audit creation",
		pattern: /Create (these )?audit(ed)? (follow-up )?issues|ISSUE AUDIT|Issue Audit\b|TPM audit complete|delegate (now )?or defer|Delegate all|Defer all/,
	},
	{
		tag: "descope-related",
		matched: "descope reconciliation",
		pattern: /Descope CC?-?[A-Z0-9-]+|FIX RECONCILIATION/,
	},
	{
		tag: "external-fix-suggestions",
		matched: "external-review fixes",
		pattern: /Apply (the )?external[- ]?review|external[- ]?review (fix|suggestion)|Apply\s+[A-Za-z0-9 \-]{1,40}\s+(fix|suggestion)s?\s+from\s+(external|second-opinion|gemini|gpt|codex)/,
	},
	{
		tag: "cycle-fix-suggestions",
		matched: "cycle-review fixes",
		pattern: /Apply (the )?fix suggestions|Apply fixes\?|Apply\s+[A-Za-z0-9 \-]{1,40}\s+(fix|suggestion)s?\s+from\s+reviewer[- ]/,
	},
	{
		tag: "multi-select-tabbed",
		matched: "tabbed checkbox select",
		pattern: /(←|→).*(☐|☒|✔|✓)|(☐|☒|✔|✓).*(←|→)/,
	},
	{
		tag: "generic-multi-choice",
		matched: "unmatched option list",
		pattern: /^\s*[1-9][.)] /m,
	},
];
