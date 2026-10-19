# Development

## Protocol

The bridge drives `codex app-server --stdio`, the JSON-RPC interface the Codex CLI ships for clients. It is the one Codex interface with a channel back to a pending tool call.

The bridge does not use `codex exec --json`. That command writes JSON Lines to standard output and reads nothing back, so a tool result has no way to reach a pending call. Codex 0.163.0 also refuses dynamic tools in exec mode (`dynamic tool calls are not supported in exec mode`).

The bridge supports exactly Codex CLI 0.163.0. It reads `codex --version` before each launch and refuses another version with `codex-version-unsupported found=<v> expected=0.163.0`. The app-server protocol is experimental, and each list in `src/codex-policy.ts` was read from that release, so a new release needs a review and a package release.

The bridge calls these 0.163.0 methods:

| Method | Use |
|---|---|
| `initialize`, `initialized` | Handshake with `experimentalApi: true` (dynamic tools need it) and `requestAttestation: false`. |
| `model/list` | The model menu. |
| `config/read` | The configured MCP server names, before each thread start and cold resume. |
| `thread/start` | A new thread with Pi's tools as `dynamicTools`. |
| `thread/resume` | A cold resume in a new app-server, with a one-turn `initialTurnsPage` to read the latest turn. |
| `experimentalFeature/list` | The feature audit for one thread. |
| `turn/start`, `turn/steer`, `turn/interrupt` | Turns, user input during a tool batch, and aborts. |

`src/protocol.ts` narrows every value read from Codex. Other modules consume its typed results.

## Threads

Codex stores a thread's dynamic tools in `CODEX_HOME` with the thread. `thread/resume` restores them and takes no new ones, so a thread serves one tool set for its whole life.

Each Pi assistant message stores `codex-thread:<thread>:<turn>:<tool signature>` as its `responseId`. The latest such message that ended with `stop` or `toolUse` is the boundary. The bridge continues the boundary's thread only when all of these hold:

- the signature matches Pi's current tools;
- only user messages, and for a `toolUse` boundary that turn's tool results, follow the boundary: another model's turn, or a pi-codex message that errored or was aborted, means Codex lacks part of the transcript;
- the thread's latest turn is the boundary's turn: the bridge's own record in the same process, or the `initialTurnsPage` of a cold resume. A cold resume of a thread the `CODEX_HOME` does not hold (Codex replies `no rollout found for thread id`) counts as a mismatch.

Otherwise it starts a new thread. The new thread's first turn carries every earlier message as one replayed text item, the images those messages held, and the trailing user messages. A tool change, a Pi tree navigation, a model switch, an aborted turn or a fresh `CODEX_HOME` therefore starts a new thread instead of failing the session. A Pi compaction keeps the thread while its latest pi-codex message survives the compaction.

The system prompt is fixed at thread start (`baseInstructions`). A later change to Pi's system prompt reaches Codex with the next new thread. The bridge does not start a new thread for it, because Pi extensions can change the prompt every turn and a replay loses Codex's own record of tool calls.

## Tool calls

Codex sends each dynamic tool call as an `item/tool/call` server request and holds the turn until the bridge answers that request. Codex 0.163.0 runs a model response's dynamic calls one at a time. A stream therefore ends with `toolUse` on the request itself, a protocol signal, never on a timer. A call already queued behind it joins the batch.

One queue per thread holds every request and notification in arrival order. A request that arrives between two Pi streams waits there for the next stream.

The next stream answers each pending call by its request id. Text becomes `inputText` and an image becomes `inputImage` with a data URL. A call without a Pi result, as after an abort during the tool, is answered `success: false` with a lost-result text. User messages after the tool results go to the same turn through `turn/steer`.

A turn the bridge does not continue, because the transcript moved to a new thread or its tools changed, has its pending calls answered as lost and is interrupted. Codex refusing an interrupt with `no active turn to interrupt` means the turn already ended; any other refusal stops the child with `codex-interrupt-failed thread=<id> turn=<id>`. An abort ends the stream at once and interrupts the turn.

## Pi stream contract

- `onPayload` receives the `turn/start` params, or `{ method: "item/tool/call", answers, steer }` for a continued turn, before the bridge sends them. A returned replacement is sent instead.
- `onResponse` receives `{ status: 200, headers: {} }` once Codex accepted the turn or the tool answers were sent.
- `onProviderStreamEvent` receives each Codex request or notification frame of the turn before the bridge reads it.
- A message's usage is that of its latest Codex model request, as Pi reads it for the context size. Codex counts cached and cache-written tokens inside its input count; the bridge reports them apart, as Pi's Responses adapter does. A message that ends with `toolUse` reports none, because Codex sends that request's usage after the tool call.
- `thinkingLevelMap` maps Pi's `off` to Codex `none` and each other level to itself. A level the model does not list maps to null, which Pi does not offer. The bridge sends the mapped effort of Pi's clamped level, or no effort where the map has none.

## Credential boundary

`auth-presence.ts::hasCodexLogin` checks only whether `CODEX_HOME/auth.json` exists. It never opens the file. A missing login throws `codex-login-missing home=<CODEX_HOME>` before any process starts, and the provider then lists no model.

`codex-environment.ts::codexChildEnvironment` passes an allowlist: `PATH`, `HOME`, locale, `TMPDIR`, proxy and CA variables, and the exact resolved `CODEX_HOME`. No other inherited variable reaches the child.

The bridge never calls a Codex login method. It refuses `account/chatgptAuthTokens/refresh`, the one server request that asks the client for credentials.

## Configured MCP servers

Codex 0.163.0 has no switch that stops every configured MCP server, and `-c mcp_servers={}` does not clear inherited servers. The bridge stops them by name:

1. Immediately before each `thread/start` and cold `thread/resume`, it calls `config/read { cwd }` on the same app-server. The JSON-RPC client decodes the reply to the server names of the merged `mcp_servers` inside the parse of the reply line. No command, argument, env value or other config field outlives that parse. A failed or malformed read refuses the thread.
2. It passes `{ mcp_servers: { <name>: { enabled: false } } }` as the thread `config`.
3. Any `mcpServer/startupStatus/updated` with `status: "starting"` refuses with `codex-mcp-started name=<n>` and stops the app-server. Codex 0.163.0 starts each stdio MCP server as the leader of its own process group, so a signal to the app-server's group does not reach it, and a SIGKILL denies Codex the teardown that stops it. The bridge therefore closes the app-server's stdin and sends SIGTERM to its group, and Codex's teardown stops the servers it started, one that outlives stdin EOF and ignores SIGTERM included. An app-server still running after 3 seconds gets SIGKILL. After the app-server exits, each process the bridge recorded below it before the first signal that still runs, with the same start time, gets SIGKILL with its group. `close` on `session_shutdown` stops the child the same way and waits for it.

The `apps`, `plugins`, `remote_plugin` and `skill_mcp_dependency_install` features, the sources of servers outside `mcp_servers`, are disabled at launch.

The name read and the thread start are two requests, so a server added between them starts, and step 3 then stops the child. A managed config layer that outranks the thread `config` is untested.

In hosted lanes the platform also guarantees an empty configured set: FLT-1396 owns that guarantee for the lane image, home and account overlay. The bridge keeps steps 1 to 3 everywhere, hosted or not.

## Native tools

Native Codex tools must not run. These guards hold that:

- The launch disables every 0.163.0 default-on feature that runs something outside Pi (`DISABLED_FEATURES`). It also sets `web_search="disabled"` and `tools.experimental_request_user_input={enabled=false}` (`LAUNCH_CONFIG`), so Codex offers the model no `request_user_input` tool: no user answers Codex here. It also sets `features.multi_agent_v2.max_concurrent_threads_per_session=1`. Models with a multi-agent runtime in the Codex catalog are offered `spawn_agent` even with the `multi_agent` feature off; this limit holds each thread tree to its root thread, so Codex refuses a spawn before the sub-agent thread exists and the sub-agent sends no model request. It enables no feature, and it does not limit the bridge's own top-level threads. The fixture suite holds both settings.
- Threads run with `sandbox: "read-only"`, `environments: []` (no environment tools, such as `apply_patch` and `exec_command`) and `approvalPolicy: "untrusted"`. Under `untrusted` Codex asks only for a command outside its known-safe set and outside the exec-policy allow rules in `CODEX_HOME`; the bridge declines each such request and refuses the turn. A known-safe or allow-rule command runs without asking, so for it the item audit below is a stop after the command starts, not a refusal before it runs. 0.163.0 has no stricter policy.
- After each thread start and resume, `experimentalFeature/list { threadId }` must report no enabled feature outside `REVIEWED_ENABLED_FEATURES`, or the thread is refused with `codex-feature-unreviewed name=<f>` before its first turn.
- An `item/started` whose type is not in `ALLOWED_ITEM_TYPES` interrupts the turn and refuses it with `codex-native-item type=<t>`.
- A turn or item on a thread the bridge did not start, such as a Codex sub-agent, stops the child and refuses with `codex-foreign-thread thread=<id>`.

`unified_exec` cannot be disabled in 0.163.0: `--disable unified_exec`, `-c features.unified_exec=false` and `experimental_use_unified_exec_tool=false` all leave it reported enabled. It is in `REVIEWED_ENABLED_FEATURES` because its `exec_command` and `write_stdin` tools are not offered while `shell_tool` is off and the thread has no environment; the fixture suite asserts that from the tools Codex sends the model. If Codex ran one anyway, the item audit (`commandExecution` is not an allowed item type) stops it after it starts, and a command outside the known-safe set and the allow rules also meets a declined approval request first.

Models whose Codex catalog entry sets `tool_mode = "code_mode_only"` reach tools only through Codex code mode. `code_mode_host` is disabled, so on those models Codex fails code mode closed and Pi's tools are unreachable. The app-server exposes no tool mode: neither `model/list` nor `modelProvider/capabilities/read` carries it, so the bridge cannot leave those models out of Pi's list.

## Model discovery

The extension factory lists models through the bridge's own app-server client, under a 15-second deadline. A stall or failure stops that child and gives an empty model list and one keyed notice at session start; a missing login gives the `codex-login-missing` notice instead. A child that lists models stays with the bridge for the session's streams until `session_shutdown`.

The client owns its child from the spawn. The version check and the handshake share a 15-second deadline in every path; a deadline, the discovery deadline or a stream abort before the handshake ends stops that child, and the next stream starts a fresh one.

## Tests

`npm run test:ci` builds the published bundle, checks TypeScript and runs two login-free suites:

- `tests/unit-*.mjs` run against `tests/lib/fake-client.mjs`, which stands in for one app-server connection, so the bridge's router, planner and streams run unchanged. `tests/unit-process.mjs` runs the version gate, the handshake deadline and the child stop against `tests/lib/stub-codex.mjs`, a stand-in `codex` executable written into the test's scratch directory, with real processes.
- `tests/fixture-*.mjs` run the real Codex CLI 0.163.0 from the `@openai/codex` dev dependency through the bridge's own start path. `tests/lib/codex-fixture.mjs` builds a scratch `CODEX_HOME` with a user marker MCP server and a trusted project that declares another, and `tests/lib/mock-responses.mjs` serves scripted model responses on 127.0.0.1 as a Codex model provider. The bridge receives that provider through its `configOverrides` test seam, which the extension factory never sets.

The fixture suites hold the MCP guards at thread start and cold resume, the startup abort, the feature audit, and the native-tool guards. Their marker MCP server outlives stdin EOF, so the late-server row shows the stop ends a server Codex started. Each row stops its world from `t.after`, which runs when the row times out, and both suites run with `--test-force-exit`, so a stalled row fails after its 30-second deadline instead of holding the CI job. They also scan the bridge's stderr, stream events, child argv and environment, and every file Codex or the bridge wrote, for the env and argument sentinels of the configured servers.

`tests/int-smoke.sh` runs Pi against the real Codex login. It runs only when `PI_CODEX_BRIDGE_LIVE=1`.
