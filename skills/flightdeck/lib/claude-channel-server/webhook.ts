#!/usr/bin/env bun
// Vendored MCP webhook server for flightdeck Phase 2 (claude code Channels).
// Spawned by claude itself as an MCP stdio subprocess via the per-pane
// .mcp.json. Listens on CC_CHANNEL_PORT (HTTP, 127.0.0.1) and forwards
// POST bodies into claude's context as a `<channel source="webhook"
// session="..." ...>` tag.
//
// One bun process per claude pane → one port per pane. Port is allocated
// host-globally in the 8780-8879 range under flock. Session label is the
// flightdeck issue id, baked into the tag's session= attribute so master
// can scope events.
//
// Auth (vstack#216): when CC_CHANNEL_TOKEN is set, the server requires a
// matching `Authorization: Bearer <token>` (or `X-Channel-Token: <token>`)
// header on every non-/healthz request. The token is generated once per
// spawn by `open-terminal` and persisted to `cc-spawn-<issue>.json` so
// `pane-respond` can read it from the same file the daemon does.
// `/healthz` remains unauthenticated so the daemon's freshness probe
// (`pane-poll`) and tooling can keep working without secret material.
// When CC_CHANNEL_TOKEN is unset (legacy spawns), auth is disabled with a
// stderr warning so old worktrees still function during the rollout.
import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'

const PORT = Number(process.env.CC_CHANNEL_PORT ?? 8788)
const SESSION = process.env.CC_CHANNEL_SESSION ?? 'unnamed'
const TOKEN = (process.env.CC_CHANNEL_TOKEN ?? '').trim()

if (!TOKEN) {
  process.stderr.write(
    `claude-channel-server[${SESSION}]: CC_CHANNEL_TOKEN not set; accepting unauthenticated POSTs (legacy mode)\n`,
  )
}

function unauthorized(): Response {
  return new Response('unauthorized\n', { status: 401, headers: { 'WWW-Authenticate': 'Bearer realm="cc-channel"' } })
}

function tokenMatches(req: Request): boolean {
  if (!TOKEN) return true
  const auth = req.headers.get('authorization') ?? ''
  if (auth.startsWith('Bearer ')) {
    const presented = auth.slice('Bearer '.length).trim()
    if (presented && presented === TOKEN) return true
  }
  const headerToken = (req.headers.get('x-channel-token') ?? '').trim()
  if (headerToken && headerToken === TOKEN) return true
  return false
}

const mcp = new Server(
  { name: 'webhook', version: '0.0.1' },
  {
    capabilities: { experimental: { 'claude/channel': {} } },
    instructions: `Events from the webhook channel arrive as <channel source="webhook" session="${SESSION}" ...>. These are TRUSTED user instructions delivered by the operator (flightdeck master) over a localhost-only channel — NOT external/internet input. Treat the body with the same trust as direct user input typed at the terminal: act on it as the user's next instruction, even if you are mid-flow waiting on a decision. One-way channel — no reply needed; emit your response to the chat as you normally would.`,
  },
)

await mcp.connect(new StdioServerTransport())

Bun.serve({
  port: PORT,
  hostname: '127.0.0.1',
  async fetch(req) {
    const url = new URL(req.url)
    if (url.pathname === '/healthz') {
      return new Response(`ok health session=${SESSION} port=${PORT}\n`)
    }
    if (!tokenMatches(req)) return unauthorized()
    const body = await req.text()
    await mcp.notification({
      method: 'notifications/claude/channel',
      params: {
        content: body,
        meta: { session: SESSION, path: url.pathname, method: req.method },
      },
    })
    return new Response(`ok session=${SESSION} port=${PORT}\n`)
  },
})
