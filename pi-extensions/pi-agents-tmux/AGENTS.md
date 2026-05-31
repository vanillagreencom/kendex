# pi-agents-tmux agent notes

- Activity broker publication lives in `extensions/subagent/activity.ts` and uses `globalThis[Symbol.for("vstack.pi.activity")]` when `pi-session-bridge` is loaded.
- Keep broker emission fail-open: subagent dispatch, steering, completion, and result retrieval must not depend on activity publish success.
- Lifecycle mapping is `subagents:*` → `agent.*`; update README and DEVELOPMENT.md when adding or renaming activity event types.
- `delegate_subagent` (issue #228) is intentionally narrow: single-mode only, authorized via `PI_SUBAGENT_CHILD_AGENT`, allowlist comes from the caller agent's `allowed-subagents:` frontmatter, pane targets rejected. Do not silently grow its schema or short-circuit the allowlist — that defeats the dev-agent-without-orchestration design. Bg one-shot runner exports `PI_SUBAGENT_CHILD_AGENT` (and `PI_SUBAGENT_CHILD_COLOR`) for authorization; only persistent pane launchers export `PI_SUBAGENT_CHILD_PANE=1`. Keep bridge env vars and tmux pane-title/inbox behavior pane-only unless tested against `pi-session-bridge`.
