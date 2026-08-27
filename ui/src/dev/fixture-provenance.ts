// Where each installed item came from — the Library's provenance rows:
// packages from the kendex subscription, one fork of a kendex skill, and
// the unmanaged items nothing installed.
import type { ProvenanceRow } from "@/bindings";
import { KENDEX_REPO } from "./fixture-catalog";
import { ACME, API, GLOBAL, proj } from "./fixture-scopes";

export function provenance(): ProvenanceRow[] {
  const acme = proj(ACME);
  const api = proj(API);
  const market = {
    origin: "marketplace",
    source: "kendex",
    repo: KENDEX_REPO,
  } as const;
  return [
    {
      scope: GLOBAL,
      kind: "skill",
      name: "code-review",
      harness: "claude",
      origin: market,
    },
    {
      scope: GLOBAL,
      kind: "command",
      name: "ship-it",
      harness: "claude",
      origin: market,
    },
    {
      scope: GLOBAL,
      kind: "skill",
      name: "release-notes",
      harness: "claude",
      origin: { origin: "own", forkedFrom: KENDEX_REPO, source: "local" },
    },
    {
      scope: GLOBAL,
      kind: "skill",
      name: "journal",
      harness: "claude",
      origin: { origin: "unmanaged" },
    },
    {
      scope: GLOBAL,
      kind: "skill",
      name: "agent-browser",
      harness: "claude",
      origin: { origin: "unmanaged" },
    },
    {
      scope: GLOBAL,
      kind: "skill",
      name: "agent-browser",
      harness: "pi",
      origin: { origin: "unmanaged" },
    },
    {
      scope: acme,
      kind: "agent",
      name: "orch",
      harness: "claude",
      origin: market,
    },
    {
      scope: acme,
      kind: "agent",
      name: "reviewer",
      harness: "claude",
      origin: market,
    },
    {
      scope: acme,
      kind: "skill",
      name: "github",
      harness: "claude",
      origin: market,
    },
    {
      scope: acme,
      kind: "skill",
      name: "github",
      harness: "codex",
      origin: market,
    },
    {
      scope: acme,
      kind: "skill",
      name: "deploy",
      harness: "claude",
      origin: market,
    },
    {
      scope: acme,
      kind: "hook",
      name: "guard",
      harness: "claude",
      origin: market,
    },
    {
      scope: acme,
      kind: "mcp-server",
      name: "postgres",
      harness: "claude",
      origin: market,
    },
    {
      scope: acme,
      kind: "skill",
      name: "scratch",
      harness: "claude",
      origin: { origin: "unmanaged" },
    },
    {
      scope: api,
      kind: "agent",
      name: "orch",
      harness: "claude",
      origin: market,
    },
    {
      scope: api,
      kind: "skill",
      name: "github",
      harness: "claude",
      origin: market,
    },
  ];
}
