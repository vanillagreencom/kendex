import type {
  AuditView,
  ItemDecl_Serialize,
  Manifest_Serialize,
  SourceRow,
} from "@/bindings";
import { personalDrift, personalSafety } from "./fixture-safety";
import { acmeHeldBack, acmeQueued, acmeSafety } from "./fixture-safety-acme";
import { ACME, API, GLOBAL, proj } from "./fixture-scopes";

export function views(): AuditView[] {
  const acme = proj(ACME);
  return [
    {
      scope: GLOBAL,
      drift: personalDrift(),
      plan: [],
      notes: [],
      warnings: [],
      safety: personalSafety(),
      heldBack: [],
      queued: [],
    },
    {
      scope: acme,
      drift: [
        {
          kind: "skill",
          name: "github",
          harness: "claude",
          scope: acme,
          state: "stale",
          detail: "newer content is available",
        },
        {
          kind: "hook",
          name: "guard",
          harness: "codex",
          scope: acme,
          state: "missing",
          detail: "not installed yet",
        },
        {
          kind: "skill",
          name: "scratch",
          harness: "claude",
          scope: acme,
          state: "unmanaged",
          detail: `${ACME}/.claude/skills/scratch`,
        },
        {
          kind: "agent",
          name: "old-helper",
          harness: "claude",
          scope: acme,
          state: "orphaned",
          detail: "left over from an earlier setup; nothing needs it anymore",
        },
        // A repo being moved onto kendex: declared here, and the tool that
        // came before already left files where it goes. One item, two
        // tools, one decision — which is what the row folds to.
        {
          kind: "skill",
          name: "release-notes",
          harness: "claude",
          scope: acme,
          state: "conflict",
          cause: "unmanaged-content",
          detail: `${ACME}/.claude/skills/release-notes already holds files kendex did not write`,
        },
        {
          kind: "skill",
          name: "release-notes",
          harness: "codex",
          scope: acme,
          state: "conflict",
          cause: "unmanaged-content",
          detail: `${ACME}/.agents/skills/release-notes already holds files kendex did not write`,
        },
      ],
      plan: [
        "Update skill github for Claude Code",
        "Install hook guard for Codex",
        "Update the install record",
      ],
      notes: [],
      warnings: [],
      safety: acmeSafety(),
      heldBack: acmeHeldBack(),
      queued: acmeQueued(),
    },
    {
      scope: proj(API),
      drift: [],
      plan: [],
      notes: [],
      warnings: [],
      safety: [],
      heldBack: [],
      queued: [],
      // Demoes the "scope couldn't be read" path: the review card and
      // Problems page both need a real error to render, not just an empty
      // clean scope, or the modal/footer/page have nothing to show.
      error: {
        kind: "lock-corrupt",
        message:
          "/home/dana/work/api-server/.kendex-lock.json: the file is not valid JSON",
      },
    },
  ];
}

const decl = (source: string): ItemDecl_Serialize => ({
  source,
  enabled: true,
});

export function manifests(): Record<string, Manifest_Serialize> {
  return {
    global: {
      schema: 1,
      sources: { kendex: { repo: "vanillagreencom/kendex", enabled: true } },
      install: { harnesses: ["claude"], method: "symlink" },
      skills: { "code-review": decl("kendex") },
      commands: { "ship-it": decl("kendex") },
    },
    [ACME]: {
      schema: 1,
      sources: {
        kendex: { repo: "vanillagreencom/kendex", enabled: true },
        team: { path: "../team-catalog", enabled: true },
      },
      install: { harnesses: ["claude", "codex", "pi"], method: "symlink" },
      agents: { orch: decl("kendex"), reviewer: decl("kendex") },
      skills: { github: decl("kendex"), deploy: decl("kendex") },
      hooks: { guard: decl("kendex") },
      "mcp-servers": { postgres: decl("kendex") },
      "agent-skills": { orch: ["github", "deploy"], reviewer: ["github"] },
      "agent-launch-instructions": { all: "Prefer small, reviewable changes." },
      "agent-frontmatter": {
        claude: { orch: { model: "opus", color: "blue" } },
      },
    },
    [API]: {
      schema: 1,
      sources: { kendex: { repo: "vanillagreencom/kendex", enabled: true } },
      install: { harnesses: ["claude"], method: "symlink" },
      agents: { orch: decl("kendex") },
      skills: { github: decl("kendex") },
    },
  };
}

export function sources(): SourceRow[] {
  const kendex = {
    name: "kendex",
    reference: "vanillagreencom/kendex",
    isRemote: true,
    enabled: true,
    head: "9f31c2a",
  };
  return [
    { scope: GLOBAL, ...kendex, declaredItems: ["code-review", "ship-it"] },
    {
      scope: GLOBAL,
      name: "claude-plugins",
      reference: "acme/claude-plugins",
      isRemote: true,
      enabled: true,
      head: "4c1d9e2",
      declaredItems: [],
    },
    {
      scope: proj(ACME),
      ...kendex,
      declaredItems: [
        "orch",
        "reviewer",
        "github",
        "deploy",
        "guard",
        "postgres",
      ],
    },
    {
      scope: proj(ACME),
      name: "team",
      reference: "../team-catalog",
      isRemote: false,
      enabled: true,
      head: null,
      declaredItems: [],
    },
    { scope: proj(API), ...kendex, declaredItems: ["orch", "github"] },
  ];
}
