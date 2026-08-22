import type {
  AuditView,
  BundleRow,
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
          subject: "package",
          detail: "newer content is available",
        },
        {
          kind: "hook",
          name: "guard",
          harness: "codex",
          scope: acme,
          state: "missing",
          subject: "package",
          detail: "not installed yet",
        },
        {
          kind: "skill",
          name: "scratch",
          harness: "claude",
          scope: acme,
          state: "unmanaged",
          subject: "package",
          detail: `${ACME}/.claude/skills/scratch`,
        },
        {
          kind: "agent",
          name: "old-helper",
          harness: "claude",
          scope: acme,
          state: "orphaned",
          subject: "package",
          detail: "left over from an earlier setup; nothing needs it anymore",
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

export function bundles(): BundleRow[] {
  const starter = {
    source: "kendex",
    name: "starter",
    description: "Everything a new repo needs",
    version: null,
    category: null,
    members: ["agent orch", "skill github", "skill deploy", "command ship-it"],
  };
  const review = {
    source: "kendex",
    name: "review",
    description: "Code review, end to end",
    version: "1.2.0",
    category: "quality",
    members: ["agent reviewer", "skill code-review"],
  };
  const platform = {
    source: "kendex",
    name: "platform",
    description: "The full platform workflow, docs to deploy",
    version: "0.9.0",
    category: "workflow",
    members: [
      "skill github",
      "skill docs",
      "skill tests",
      "skill release-notes",
      "command ship-it",
      "mcp-server postgres",
    ],
  };
  return [
    { scope: GLOBAL, ...starter, installed: false },
    { scope: GLOBAL, ...review, installed: true },
    { scope: GLOBAL, ...platform, installed: false },
    // A plugin registry's plugins are its curated sets.
    {
      scope: GLOBAL,
      source: "claude-plugins",
      name: "deploy-kit",
      description: "Release and rollback, as one set",
      version: "2.1.0",
      category: null,
      members: [
        "agent deploy-kit/release-manager",
        "command deploy-kit/rollback",
      ],
      installed: false,
    },
    {
      scope: GLOBAL,
      source: "claude-plugins",
      name: "docs-kit",
      description: "Documentation, outlined and styled",
      version: "1.0.3",
      category: null,
      members: [
        "agent docs-kit/writer",
        "command docs-kit/outline",
        "skill docs-kit/style-guide",
      ],
      installed: false,
    },
    { scope: proj(ACME), ...starter, installed: true },
    { scope: proj(ACME), ...review, installed: false },
    { scope: proj(ACME), ...platform, installed: false },
  ];
}
