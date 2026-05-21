export const INSTALL_SYMBOL = Symbol.for("vstack.pi-qol.installed");
export const CONFIG_ID = "@vanillagreen/pi-qol";

export const STATUS_KEY = "qol-attachments";
export const SESSION_SEARCH_STATUS_KEY = "qol-session-search";
export const SESSION_SEARCH_CONTEXT_TYPE = "qol-session-context";
export const CONTEXT_USAGE_MESSAGE_TYPE = "qol-context-usage";
export const SESSION_MANAGER_STATUS_KEY = "session-manager";

export const IMAGE_EXTENSIONS = new Set([".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tif", ".tiff", ".heic", ".heif"]);
export const IMAGE_PATH_PATTERN = /(^|[\s(\[{<"'`])(@?(?:~|\.\.?|\/)[^\s)\]}>"'`]+?\.(?:png|jpe?g|gif|webp|bmp|tiff?|heic|heif))(?=$|[\s)\]}>"'`,.;:!?])/gi;

export const QUESTION_SERVICE_SYMBOL = Symbol.for("vstack.pi-questions.service");
export const QOL_NOTIFICATION_SERVICE_SYMBOL = Symbol.for("vstack.pi-qol.notification-service");
export const VSTACK_MODAL_LOCK_SYMBOL = Symbol.for("vstack.pi.modal-lock");
export const CAVEMAN_BRIDGE_SYMBOL = Symbol.for("vstack.pi.caveman");
export const PI_AGENTS_STATUSLINE_SYMBOL = Symbol.for("vstack.pi-agents-tmux.statusline");

export const CAVEMAN_ICON_ACTIVE = "\uee9a";
export const CAVEMAN_ICON_INACTIVE = "\u{f19e0}";

export const THINKING_TIMER_STORE_SYMBOL = Symbol.for("vstack.pi-qol.thinking-timer.store");
export const THINKING_TIMER_PATCH_SYMBOL = Symbol.for("vstack.pi-qol.thinking-timer.patch");
export const SESSION_SEARCH_PENDING_SYMBOL = Symbol.for("vstack.pi-qol.session-search.pending-context");
export const PENDING_QUEUE_THEME_PATCH_SYMBOL = Symbol.for("vstack.pi-qol.pending-queue.theme-patch");
export const STATUS_TEXT_ALIGNMENT_PATCH_SYMBOL = Symbol.for("vstack.pi-qol.status-text-alignment-patch");

export const QUESTION_OPENED_EVENT = "vstack:pi-questions:opened";
export const QUESTION_NOTIFY_DEDUP_MS = 2000;

export const DEFAULT_NOTIFICATION_TITLE = "Pi";
export const DEFAULT_NOTIFICATION_COOLDOWN_SECONDS = 8;
export const DEFAULT_NOTIFICATION_BODY_MAX_CHARS = 240;
export const DEFAULT_TMUX_MESSAGE_DURATION_MS = 5000;

export const DEFAULT_COMPACTION_MODEL = "current";
export const DEFAULT_COMPACTION_MAX_TOKENS = 8192;
export const DEFAULT_IDLE_COMPACTION_THRESHOLD_TOKENS = 200000;
export const DEFAULT_IDLE_COMPACTION_SECONDS = 300;

// Budget guard: catches long autonomous sessions before they hit provider/buffer
// limits. Fires on agent_end (no idle wait) when usage crosses a percent or
// absolute token threshold. One notification + one compaction trigger per
// threshold crossing so it does not loop.
export const DEFAULT_BUDGET_GUARD_PERCENT = 85;
export const DEFAULT_BUDGET_GUARD_TOKENS = -1;

// Chunked summary input caps. Long transcripts are split on paragraph
// boundaries (which align with serializeConversation message separators) into
// chunks of at most this many characters, summarized chunk-by-chunk in the
// original order, then a summary-of-summaries reduce pass merges them with
// "prefer the most recent" semantics so recency is preserved.
export const DEFAULT_BUDGET_MAX_INPUT_CHARS = 240_000;

// Transcript-risk warning: shown in /context when the serialized payload of
// messages-to-send is larger than this character budget, even if token count is
// still below the model window.
export const DEFAULT_TRANSCRIPT_RISK_WARN_CHARS = 600_000;

export const QOL_BUDGET_HANDOFF_FOLDER = "pi-qol/handoff";
export const QOL_BUDGET_HANDOFF_LATEST = "latest.json";

export const DEFAULT_PERMISSION_GATE_COMMANDS = "rm -Rf";
export const DEFAULT_PERMISSION_GATE_PREVIEW_LINES = 12;
export const DEFAULT_PERMISSION_GATE_PREVIEW_CHARS = 1200;
export const DEFAULT_PERMISSION_GATE_PREVIEW_LINE_WIDTH = 120;

export const DEFAULT_SESSION_SEARCH_LIMIT = 40;
export const DEFAULT_SESSION_SEARCH_PREVIEW_SNIPPETS = 6;
export const DEFAULT_SESSION_SEARCH_SHORTCUT = "f2";
export const DEFAULT_SESSION_SEARCH_SUMMARY_INPUT_CHARS = 180_000;
export const DEFAULT_SESSION_SEARCH_SUMMARY_MAX_TOKENS = 4096;
export const DEFAULT_SESSION_SEARCH_CACHE_TTL_SECONDS = 0;
export const SESSION_SEARCH_OVERLAY_HEIGHT_RATIO = 0.9;

export const DEFAULT_AUTO_RENAME_MODEL = "openai-codex/gpt-5.4-mini";
export const DEFAULT_AUTO_RENAME_FALLBACK_MODEL = "current";
export const DEFAULT_AUTO_RENAME_INPUT_CHARS = 2000;
export const DEFAULT_AUTO_RENAME_NAME_CHARS = 80;
export const DEFAULT_AUTO_RENAME_MAX_TOKENS = 96;
export const DEFAULT_AUTO_RENAME_TIMEOUT_MS = 12_000;
export const DEFAULT_INPUT_BOTTOM_PADDING_LINES = 0;

export const SESSION_TITLE_SYNC_INTERVAL_MS = 1000;

// tmux trims plain leading/trailing spaces from pane-border-format output, so
// use NBSP padding. Terminals render it as a space, but tmux keeps it visible.
export const TMUX_SESSION_TITLE_PAD = "\u00a0";
export const TMUX_SESSION_TITLE_BORDER_FORMAT = `${TMUX_SESSION_TITLE_PAD}#{pane_title}${TMUX_SESSION_TITLE_PAD}`;

export const THINKING_LABEL_DEFAULT = "\ue28c ";

export const QOL_COMPACTION_SYSTEM_PROMPT = "You summarize coding-agent sessions for continuation. Preserve exact technical facts, filenames, commands, constraints, decisions, blockers, and next actions. Do not invent details.";

export const AUTO_RENAME_SYSTEM_PROMPT = "You create short, descriptive session names for coding-agent chats. Use 2-6 words in Title Case. Respond with only the name, no quotes, explanations, markdown, emoji, or trailing punctuation.";

export const DEFAULT_AUTO_RENAME_PROMPT = `Generate a short, descriptive title for this Pi coding-agent session based on the first user message.

Rules:
- Use 2-6 words
- Use Title Case
- Be specific about the user's task or topic
- Do not mention Pi unless Pi itself is the task
- Return only the title

First user message:
{{message}}`;

export const HANDOFF_SYSTEM_PROMPT = `You are a context transfer assistant. Given a conversation history and the user's goal for a new thread, generate a focused prompt that:

1. Summarizes relevant context from the conversation (decisions made, approaches taken, key findings)
2. Lists any relevant files that were discussed or modified
3. Clearly states the next task based on the user's goal
4. Is self-contained - the new thread should be able to proceed without the old conversation

Format your response as a prompt the user can send to start the new thread. Be concise but include all necessary context. Do not include any preamble like "Here's the prompt" - just output the prompt itself.

Example output format:
## Context
We've been working on X. Key decisions:
- Decision 1
- Decision 2

Files involved:
- path/to/file1.ts
- path/to/file2.ts

## Task
[Clear description of what to do next based on user's goal]`;
