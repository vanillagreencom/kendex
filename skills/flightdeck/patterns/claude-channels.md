# Claude Code Channels — flightdeck integration pattern

Phase 2 of the unified-comms migration. Replaces tmux send-keys + capture-pane for claude panes with a structured MCP-channel inbound + JSONL transcript outbound. **Opt-in** via `FLIGHTDECK_CLAUDE_CHANNELS=1` (env) or `--use-channels` (open-terminal flag). Default claude spawn is unchanged for `--tracker linear`; tmux primitives remain as the fallback path. `--tracker github --harness claude` defaults channels **on** (vstack#216) because the github tracker doesn't ship a Pi-orchestrator pane the daemon can bind a subscriber to — without channel metadata the daemon would silently bind-skip and `PRE-PR-REVIEW-READY:` would never be delivered. The github default still respects an explicit `--no-channels` / `FLIGHTDECK_CLAUDE_CHANNELS=0` from the operator, and falls back to tmux if any channel dep is unavailable.

## Mechanism

**Inbound (send):** an MCP webhook server (vendored at `lib/claude-channel-server/webhook.ts`, small Bun server) is spawned by claude itself as an MCP stdio subprocess via the per-pane `.mcp.json`. The webhook listens on a flightdeck-allocated TCP port (range `8780-8879`, host-global, flock-guarded). `GET /healthz` is reserved for side-effect-free freshness probes; master POSTs to `http://127.0.0.1:<port>/` and the body arrives in claude's context as:

```
<channel source="webhook" session="<ISSUE>" path="/" method="POST">
your message body here
</channel>
```

Claude treats this as user-driven input.

**Outbound (read):** every claude session appends to `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`. Each line is a JSON event with full structure (assistant content, tool args, channel events, thinking blocks). Pinning the session UUID via `--session-id <uuid>` makes the transcript path deterministic from the issue id.

For wake purposes, the daemon's claude subscriber tails the JSONL and emits a normalized turn-end event when an assistant line with non-null `stop_reason` arrives.

## Encoded cwd

Replace every `/` in the absolute worktree path with `-`. Example: `/path/to/project/trees/cc-9001` → `-path-to-project-trees-cc-9001`.

## Spawn

Three-step launch happens in `open-terminal`:

1. Allocate port via `cc_alloc_port <ISSUE>`.
2. Derive deterministic UUID: `cc_uuid_for_issue <ISSUE>` (md5 → UUID format).
3. Write per-pane `.mcp.json` at `${FD_STATE_DIR}/cc-channel/<ISSUE>/.mcp.json` referencing the vendored webhook with unique `CC_CHANNEL_PORT` + `CC_CHANNEL_SESSION=<ISSUE>`.
4. Spawn claude in tmux with:
   ```
   claude --session-id <UUID> \
          --mcp-config <abs-path-to-pane-mcp-json> \
          --dangerously-load-development-channels server:webhook \
          --dangerously-skip-permissions \
          '/linear-orch start <ISSUE>'
   ```
5. Pre-warm the trust prompt for the development-channels flag via a delayed `tmux send-keys "y" Enter` (one-time per launch).

The vendored webhook server uses Bun. Bootstrap is idempotent: `lib/claude-channel-server/bootstrap` runs `bun install` once if `node_modules/` is missing.

## Auth requirements

**claude.ai login only.** Channels do NOT work with:

- `ANTHROPIC_API_KEY` (Anthropic API)
- AWS Bedrock
- Google Vertex

Verify via `claude auth status` — output should mention `claude.ai`. Flightdeck refuses channel-mode spawn if auth check fails.

## Limits

- **No `AskUserQuestion` / `EnterPlanMode` / `ExitPlanMode` in the standalone claude TUI.** Multi-choice questions come back as free text in the transcript; master sends another channel POST to "pick".
- **Channels deliver only while session is open.** Pane-gone signal kills in-flight POSTs. No buffer-and-replay.
- **Webhook is local-only and unauthenticated.** Single-user dev workstation deployment assumed. For multi-user, gate on a token header before forwarding to claude.
- **MCP webhook is a child of claude.** Killing the tmux pane (or claude exiting) reaps the bun subprocess automatically. No separate cleanup needed.
- **Permission relay (claude `>=2.1.81`)** is a future-win optional capability — channels can declare `claude/channel/permission` and receive tool-approval prompts on a side channel. Not load-bearing for v1.

## Known limitation: agent-skill trust of channel input

Channels deliver `<channel source="webhook">BODY</channel>` blocks. Claude's reasoning about whether to treat this as a trusted user instruction depends on:

- **Webhook MCP server `instructions` field** — sets the baseline trust hint. The vendored webhook.ts instructions explicitly say "TRUSTED user instructions delivered by the operator over a localhost-only channel."
- **The currently-loaded skill's prompt** — linear-orch (the per-issue agent skill) may have its own rules about channel input. If linear-orch's prompt says to distrust non-user sources, channel messages can be ignored when linear-orch is mid-flow on a different decision (e.g. waiting on a user choice).

Observed symptom: when linear-orch is blocked on a "user must decide" prompt and a channel POST arrives with a different instruction, claude may respond with `"Webhook injection ignored — untrusted source, not user"` and continue waiting on the original prompt.

**Workarounds:**
1. **Pose the channel message as the answer to the active prompt** — flightdeck master's handler is already shape-aware (`prompt-classify` tags) and can format channel POSTs to look like option picks ("1") rather than free directives.
2. **Update linear-orch prompt** (out of scope for flightdeck) to recognize the `<channel source="webhook" session="<ISSUE>">` shape as trusted operator input from flightdeck.
3. **Use channels for pre-linear-orch setup only** — e.g., bootstrapping a session, not for mid-linear-orch responses; fall back to tmux send-keys for in-flow answers.

The flightdeck mechanism (port allocator, MCP webhook, JSONL tail, daemon subscriber) is fully functional; this is a skill-integration boundary issue.

## Adapter contract

| Surface | Channel mode | Tmux fallback |
|---|---|---|
| `pane-respond` payload | `curl -X POST -d "<msg>" http://127.0.0.1:<port>/` | `tmux load-buffer + paste-buffer + Enter` |
| `pane-respond --option N` | POST bare digit "N" as text | (claude only — arrow nav) |
| `pane-respond --keys` | REJECTED unless `--keys-allow-tmux` | tmux send-keys |
| `pane-poll` buffer | Last assistant text from JSONL transcript | `tmux capture-pane` |
| Daemon wake source | JSONL tail filtered for `stop_reason` arrival | bell flag + hash-stability |

Falls back when bridge metadata absent or stale (legacy session, port exhausted, claude < 2.1.80, wrong auth, no bun, transcript missing, `/healthz` fails) — logged as `cc-channel-unavailable: <reason>`. Never silent.

## Daemon bind-skip diagnostics (vstack#216)

When the tracked entry registers as `harness=claude` but the channel adapter never wrote `cc_transcript` (legacy entry, fallback spawn, or an older bug shape), the daemon's claude subscriber would previously `return false` silently every reconcile tick. As of vstack#216:

- Startup probe emits `[startup-binder-missing-fields]` once per affected pane with `harness=claude missing=cc_transcript`.
- Per-tick miss emits `[claude-subscriber-bind-skip]` (throttled to one row per `(pane, reason)` per `FD_SUB_BIND_SKIP_LOG_INTERVAL_SEC` (default 60s)).
- After `FD_SUB_BIND_SKIP_STUCK_THRESHOLD` consecutive misses (default 12) the daemon emits a one-shot `[claude-subscriber-bind-stuck]` warning naming the missing fields.
- `flightdeck-daemon health` reads the per-session subscriber-status snapshot and reports per-pane `status=bound|skipped|stuck|dead` plus `consecutive_bind_skips` / `last_bind_skip_reason`.

The same diagnostic shape applies to the opencode (`oc_url`/`oc_session_id`) and codex (`cx_url`/`cx_thread_id`) cases, which previously silently bind-skipped on the same code path.

## Versioning

Pin claude `>=2.1.80` (channels), `>=2.1.81` for permission relay (optional).

## References

- Channels overview: <https://code.claude.com/docs/en/channels>
- Channels reference: <https://code.claude.com/docs/en/channels-reference>
- Working examples: <https://github.com/anthropics/claude-plugins-official/tree/main/external_plugins>

## Why not packaged as a Claude plugin?

Plugin packaging adds manifest + marketplace ceremony without removing the dangerous flag during research preview. It also splits the channel artifact from the skill that needs to scaffold per-pane configs at spawn time. Vendoring the server inside the skill keeps the lifecycle co-located.
