// The subscriptions themselves: the kendex catalog subscribed in three
// scopes, a plugin registry, and a path subscription not fetched yet — plus
// what each readable subscription offers, with a curated set partly
// installed (2 of 6 in acme-web). The offered items live in
// fixture-catalog.ts.
import type {
  AboutView,
  AvailablePackage,
  CatalogSummary,
  MarketplaceRow,
  Scope,
} from "@/bindings";
import {
  KENDEX_HEAD,
  KENDEX_OFFERED,
  KENDEX_REPO,
  type Offered,
  PLUGINS_HEAD,
  PLUGINS_OFFERED,
  PLUGINS_REPO,
} from "./fixture-catalog";
import { ACME, API, GLOBAL, proj } from "./fixture-scopes";

export const packagesKey = (scope: Scope, source: string): string =>
  `${scope.scope === "global" ? "global" : scope.root}::${source}`;

const packageList = (offered: Offered[], installed: string[]) =>
  offered.map(
    (pkg): AvailablePackage => ({
      kind: pkg.kind,
      name: pkg.name,
      description: pkg.description,
      tags: pkg.tags,
      bundles: pkg.bundles,
      state: installed.includes(`${pkg.kind} ${pkg.name}`)
        ? "installed"
        : "available",
      collision: null,
    }),
  );

// Mirrors fixture-declared's manifests: what each scope declares from the
// kendex subscription.
const GLOBAL_INSTALLED = ["skill code-review", "command ship-it"];
const ACME_INSTALLED = [
  "agent orch",
  "agent reviewer",
  "skill github",
  "skill deploy",
  "hook guard",
  "mcp-server postgres",
];
const API_INSTALLED = ["agent orch", "skill github"];

export function marketplacePackages(): Record<string, AvailablePackage[]> {
  return {
    [packagesKey(GLOBAL, "kendex")]: packageList(
      KENDEX_OFFERED,
      GLOBAL_INSTALLED,
    ),
    [packagesKey(GLOBAL, "claude-plugins")]: packageList(PLUGINS_OFFERED, []),
    [packagesKey(proj(ACME), "kendex")]: packageList(
      KENDEX_OFFERED,
      ACME_INSTALLED,
    ),
    [packagesKey(proj(API), "kendex")]: packageList(
      KENDEX_OFFERED,
      API_INSTALLED,
    ),
  };
}

const counts = (offered: Offered[]) => {
  const out: Record<string, number> = {};
  for (const pkg of offered) {
    out[pkg.kind] = (out[pkg.kind] ?? 0) + 1;
  }
  return out;
};

/** Which subscription fixture backs each listed repository: its packages,
 * bundle specs and About report are that source's. */
export const REPO_FIXTURE_SOURCE: Record<string, string> = {
  "acme/agent-kit": "kendex",
  "wshobson/agents": "claude-plugins",
  "vercel-labs/agent-skills": "kendex",
};

/** What the Community tab's listed repositories offer when opened before
 * subscribing — the kendex catalog's packages, unsubscribed. A listed repo
 * absent here reads as unreachable, so the page's error path is exercised. */
export function repoPackages(): Record<string, AvailablePackage[]> {
  return {
    "acme/agent-kit": packageList(KENDEX_OFFERED, []),
    "wshobson/agents": packageList(PLUGINS_OFFERED, []),
    "vercel-labs/agent-skills": packageList(KENDEX_OFFERED, []),
  };
}

export const repoSummaries: Record<
  string,
  Omit<CatalogSummary, "subscription">
> = {
  "acme/agent-kit": {
    provenance: "acme/agent-kit",
    repoKey: "acme/agent-kit",
    commit: "9f3a1c2d4e5f60718293a4b5c6d7e8f901234567",
    meta: {
      description: "Agent kit for TypeScript teams",
      author: "Acme",
      license: "MIT",
      tags: ["typescript", "agents"],
    },
    mode: "explicit",
    counts: counts(KENDEX_OFFERED),
    warning: null,
  },
  "wshobson/agents": {
    provenance: "wshobson/agents",
    repoKey: "wshobson/agents",
    commit: PLUGINS_HEAD,
    meta: null,
    mode: "plugin-registry",
    counts: counts(PLUGINS_OFFERED),
    warning:
      "wshobson/agents: using cached version (could not reach github.com)",
  },
  "vercel-labs/agent-skills": {
    provenance: "vercel-labs/agent-skills",
    repoKey: "vercel-labs/agent-skills",
    commit: KENDEX_HEAD,
    meta: null,
    mode: "discovered",
    counts: counts(KENDEX_OFFERED),
    warning: null,
  },
};

export function marketplaces(): MarketplaceRow[] {
  const kendex = {
    name: "kendex",
    repo: KENDEX_REPO,
    repoKey: KENDEX_REPO,
    path: null,
    rev: null,
    commit: KENDEX_HEAD,
    enabled: true,
    counts: counts(KENDEX_OFFERED),
    meta: {
      name: "Kendex",
      description:
        "The default marketplace — skills, agents, and hooks for coding agents",
      author: "vanillagreen",
      license: "MIT",
      homepage: "https://kendex.ai",
      tags: ["automation", "review"],
    },
    mode: "explicit" as const,
  };
  return [
    { scope: GLOBAL, ...kendex },
    {
      scope: GLOBAL,
      name: "claude-plugins",
      repo: PLUGINS_REPO,
      repoKey: PLUGINS_REPO,
      path: null,
      rev: null,
      commit: PLUGINS_HEAD,
      enabled: true,
      counts: counts(PLUGINS_OFFERED),
      meta: null,
      mode: "plugin-registry",
    },
    { scope: proj(ACME), ...kendex },
    {
      scope: proj(ACME),
      name: "team",
      repo: null,
      repoKey: null,
      path: "../team-catalog",
      rev: null,
      commit: null,
      enabled: true,
      counts: null,
      meta: null,
      mode: null,
    },
    { scope: proj(API), ...kendex },
  ];
}

export const aboutViews: Record<string, AboutView> = {
  kendex: {
    mode: "explicit",
    found: [
      { root: "agents/", kind: "agent", count: 2 },
      { root: "skills/", kind: "skill", count: 7 },
      { root: "hooks/", kind: "hook", count: 1 },
      { root: "commands/", kind: "command", count: 1 },
      { root: "mcp-servers/", kind: "mcp-server", count: 1 },
    ],
    findings: [],
  },
  "claude-plugins": {
    mode: "plugin-registry",
    found: [
      { root: "plugin deploy-kit", kind: "agent", count: 1 },
      { root: "plugin deploy-kit", kind: "command", count: 1 },
      { root: "plugin docs-kit", kind: "agent", count: 1 },
      { root: "plugin docs-kit", kind: "command", count: 1 },
      { root: "plugin docs-kit", kind: "skill", count: 1 },
    ],
    findings: [
      {
        location: ".claude-plugin/marketplace.json",
        problem: "plugin 'deploy-kit' declares no description",
        fix: "add a description so a directory can say what it offers",
      },
    ],
  },
};
