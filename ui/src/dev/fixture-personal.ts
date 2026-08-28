// Shared building blocks for the "Personal" (global) scope fixture: named
// once here so the Library listing (fixture-observed) and the audit view
// (fixture-declared/fixture-safety) describe the exact same hooks and
// plugins instead of drifting apart as the fixture grows.
import type { Finding, HarnessId } from "@/bindings";

export const CLAUDE_HOOK_IDS = [
  "Notification:permission_prompt:tmux-bell",
  "PreToolUse:*:claude-hook",
  "PostToolUse:*:claude-hook",
  "UserPromptSubmit:*:claude-hook",
  "SessionStart:*:claude-hook",
  "Stop:*:claude-hook",
  "SubagentStop:*:claude-hook",
];

// Every hook shells out through the same wrapper script, so the same line
// of the same settings file trips the same finding for all seven.
export const HOOK_SETTINGS_PATH = "/home/method/.claude/settings.json";
export const HOOK_FINDING: Finding = {
  rule: "dangerous-commands",
  severity: "high",
  location: HOOK_SETTINGS_PATH,
  line: 17,
  message: "`mkfs` formats a filesystem",
  remediation:
    "narrow the command to the exact path it needs, and let the user see it before it runs",
};

export const CLEAN_PLUGINS = [
  "caveman@caveman",
  "frontend-design@claude-plugins-official",
  "commit-helper@claude-plugins-official",
  "pr-review@claude-plugins-official",
  "changelog@claude-plugins-official",
];

// A declared-but-not-installed plugin has no files on disk yet, so every
// rule that would read its content is skipped for the same reason.
export const CLEAN_SKIP_REASON =
  "the plugin's own files are not readable here — a declared plugin is one switch in a settings file until it is installed";
export const CLEAN_SKIP_RULES = [
  "credential-theft",
  "dangerous-commands",
  "prompt-injection",
  "supply-chain-risk",
  "excessive-permissions",
  "obfuscated-code",
  "network-exfiltration",
  "destructive-file-ops",
];

export const CODEX_PLUGINS = [
  "browser@openai-bundled",
  "chrome@openai-bundled",
  "web-search@openai-bundled",
  "file-search@openai-bundled",
  "image-gen@openai-bundled",
  "code-interpreter@openai-bundled",
  "pdf-reader@openai-bundled",
  "spreadsheet@openai-bundled",
  "calendar@openai-bundled",
  "email-draft@openai-bundled",
  "translate@openai-bundled",
  "diagram@openai-bundled",
  "shell-exec@openai-bundled",
  "git-tools@openai-bundled",
  "http-client@openai-bundled",
  "json-tools@openai-bundled",
  "markdown-preview@openai-bundled",
  "regex-tester@openai-bundled",
  "sql-runner@openai-bundled",
  "unit-convert@openai-bundled",
  "weather@openai-bundled",
];

// Codex records every enabled plugin in one registry file, so the same two
// findings land on the same location for all four bundled plugins.
export const CODEX_PLUGINS_PATH = "/home/method/.codex/plugins";
export const CODEX_FINDINGS: Finding[] = [
  {
    rule: "plugin-source-trust",
    severity: "medium",
    location: `${CODEX_PLUGINS_PATH}/registry.json`,
    line: null,
    message:
      "installed from a repository kendex never recorded, so there's no way to tell what changed since",
    remediation: "reinstall it through kendex so the source is tracked",
  },
  {
    rule: "no-manifest",
    severity: "low",
    location: `${CODEX_PLUGINS_PATH}/registry.json`,
    line: null,
    message:
      "this plugin carries no manifest, so nothing on disk says what it is or who wrote it",
    remediation:
      "check with the plugin's author for a manifest, or remove it if you don't use it",
  },
];

export const UNMANAGED_SKILLS: {
  name: string;
  harness: HarnessId;
  description: string;
  path: string;
}[] = [
  // Same skill, installed by hand for two harnesses — the case the
  // "not managed yet" list merges into one row instead of two.
  {
    name: "agent-browser",
    harness: "claude",
    description: "Browser automation CLI for AI agents",
    path: "/home/method/.claude/skills/agent-browser",
  },
  {
    name: "agent-browser",
    harness: "pi",
    description: "Browser automation CLI for AI agents",
    path: "/home/method/.pi/agent/skills/agent-browser",
  },
  {
    name: "journal",
    harness: "claude",
    description: "Daily engineering notes, kept outside any repo",
    path: "~/.claude/skills/journal",
  },
  {
    name: "changelog-draft",
    harness: "codex",
    description: "Turns a diff into a changelog entry",
    path: "~/.codex/skills/changelog-draft",
  },
  {
    name: "scratchpad",
    harness: "opencode",
    description: "A place to paste things mid-task",
    path: "~/.config/opencode/skills/scratchpad",
  },
  {
    name: "voice-notes",
    harness: "pi",
    description: "Transcribes a voice memo into a task list",
    path: "~/.pi/skills/voice-notes",
  },
];
