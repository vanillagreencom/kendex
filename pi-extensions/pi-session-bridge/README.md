# pi-session-bridge

![Session bridge CLI flow](https://raw.githubusercontent.com/vanillagreencom/vstack/main/pi-extensions/pi-session-bridge/assets/session-bridge-cli.png)

Control a running Pi session from outside the TUI. The interactive Pi terminal stays visible; a Unix-domain socket exposes a structured JSONL side channel for external clients.

## Highlights

- External clients send prompts, steering, follow-ups, and aborts over a structured socket; plain text and expanded skills avoid tmux key injection, while extension/TUI slash commands use a guarded own-pane tmux route.
- Subscribe to live Pi events (messages, tool calls, agent end) without scraping panes.
- Activity broker at `Symbol.for("vstack.pi.activity")` lets local extensions publish structured `vstack_activity` events to the bridge stream without chat noise.
- Discover active Pi sessions through registry files; target by pid, cwd, session, or name.
- `pi-bridge` CLI handles common operations; raw JSONL protocol is documented for any language.
- When `pi-questions` is loaded, external clients can list, answer, and reject pending questions.

## Install

Via [npm](https://www.npmjs.com/package/@vanillagreen/pi-session-bridge):

```bash
pi install npm:@vanillagreen/pi-session-bridge
```

Via [vstack](https://github.com/vanillagreencom/vstack):

```bash
cargo install --git https://github.com/vanillagreencom/vstack.git vstack
vstack add vanillagreencom/vstack --pi-extension pi-session-bridge --harness pi -y
```

Restart Pi after installation.

`pi-bridge` is symlinked into the install scope's `bin/` (`.pi/bin/pi-bridge` project, `~/.pi/agent/bin/pi-bridge` global). Add the directory to `PATH` or run by path.

## Commands

| Command | Action |
| --- | --- |
| `/bridge:status` | Show socket and registry paths. |
| `/bridge:ping [text]` | Emit a `bridge_pong` event without calling a model. |

## `pi-bridge` CLI

```bash
pi-bridge list
pi-bridge state --pid <pid>
pi-bridge commands --pid <pid>
pi-bridge stream --pid <pid>
pi-bridge history --pid <pid> 20
pi-bridge send --pid <pid> "message for the agent"
pi-bridge steer --pid <pid> "steer current work"
pi-bridge follow-up --pid <pid> "after you finish, do this"
pi-bridge questions --pid <pid>
pi-bridge answer --pid <pid> --request-id que_... --answers '[["Stop here"]]'
pi-bridge reject --pid <pid> --request-id que_...
pi-bridge emit --pid <pid> "hello"
```

If exactly one active bridge exists, target flags are optional. Filters: `--pid`, `--socket`, `--session`, `--name`, `--cwd`.

## Raw protocol

Connect to the advertised Unix socket and exchange one JSON object per LF-delimited record. Requests may include `id`; responses use `type:"response"` with the same `id`.

Example requests:

```json
{"id":"1","type":"get_state"}
{"id":"2","type":"prompt","message":"Run tests","deliverAs":"auto"}
{"id":"3","type":"steer","message":"Focus on errors"}
{"id":"4","type":"follow_up","message":"Summarize when done"}
{"id":"5","type":"abort"}
```

Example response and event:

```json
{"type":"response","id":"1","command":"get_state","success":true,"data":{}}
{"type":"event","event":"message_update","timestamp":"...","data":{}}
{"type":"event","event":"vstack_activity","timestamp":"...","data":{"type":"agent.task_completed","source":"pi-agents","severity":"success","importance":"normal","summary":"agent done"}}
```

Clients receive events by default. Send `{"type":"subscribe","enabled":false}` to mute them. `vstack_activity` rows are bridge events, not `sendMessage()` chat entries, so they do not render in the conversation.

## Activity broker

`pi-session-bridge` exposes an in-process broker at `globalThis[Symbol.for("vstack.pi.activity")]` for local Pi extensions:

```ts
interface PiActivityBroker {
  publish(event: PiActivityEvent): void;
  subscribe(listener: (event: PiActivityEvent) => void): () => void;
  recent(limit?: number): PiActivityEvent[];
}
```

`publish()` is best-effort and fail-open. The broker keeps a 100-event ring buffer; `recent(limit)` returns newest-first validated events for in-process replay. `pi-bridge stream` emits live broker publications as `event:"vstack_activity"` only while the bridge is connected; external clients that need earlier rows must use an in-process consumer before they leave the ring.

## Slash command notes

`pi-bridge send` uses a hybrid slash dispatch path:

- Plain text keeps the normal `sendUserMessage` path.
- `/skill:<name> ...` expands client-side from the loaded skill's `sourceInfo.path`, inlining the same `<skill ...>` block Pi's editor would produce the first time a skill is loaded in a Pi session.
- Repeated `/skill:<name> ...` sends in the same Pi session skip the `SKILL.md` body and send `Skill <name> (previously loaded). Invocation: ...` instead. Changing the `SKILL.md` file content changes its hash and forces a fresh full expansion; restarting the bridge loses the in-memory cache, so the next send expands fully again.
- Prompt templates (`/<name> ...` from loaded prompt paths) expand client-side with Pi-compatible `$1`, `$@`, `$ARGUMENTS`, and `${@:N[:L]}` substitution; unquoted spaces, tabs, and newlines split arguments, while quoted newlines stay inside the argument.
- Extension/TUI commands (for example `/bridge:ping`, `/tasks:add`, `/flightdeck`) are pasted into Pi's own tmux pane with `send-keys -l` + enter after resolving the pane by walking parent processes from `process.pid`. This briefly shows text in the editor and always delivers immediately (`deliverAs` does not apply to this route).
- If tmux pane resolution or paste fails, the bridge falls back to the old raw `sendUserMessage` behavior instead of failing the request.

## Settings

Open `/extensions:settings`; settings appear under the **Session Bridge** tab.

| Setting | What it does |
| --- | --- |
| Enable session bridge | Master toggle for bridge socket registration, CLI access, and status reporting. |
| Bridge directory | Override the sockets/registry directory. `PI_BRIDGE_DIR` env var still wins. |
| Event history limit | Events retained for history clients. |
| Max request line bytes | Maximum JSONL request size accepted. |
| Registry heartbeat | Ms between registry file updates. |
| Notify on start | In-TUI notification when the bridge starts. |
| Show status badge | Show `bridge:<pid>` in the Pi footer. |

## Security

The socket can trigger real agent work in the owning Pi process. Keep `PI_BRIDGE_DIR` private. Don't expose the socket to other users or untrusted containers.
