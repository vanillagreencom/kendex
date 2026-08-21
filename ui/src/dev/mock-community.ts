// The Community tab against canned data: a directory with a featured row,
// an already-subscribed row, and a skills.sh search that answers for
// "react" and comes back empty for anything else.
import type { DirectoryView, SkillsShHit } from "@/bindings";
import type { Handler } from "./mock-state";

const directory: DirectoryView = {
  rows: [
    {
      repo: "acme/agent-kit",
      repoKey: "acme/agent-kit",
      name: "agent-kit",
      description: "Agent kit for TypeScript teams",
      tags: ["typescript", "agents"],
      featured: true,
      packageCount: 12,
      bundleCount: 2,
      subscribed: false,
      packages: [],
      bundles: [],
    },
    {
      repo: "wshobson/agents",
      repoKey: "wshobson/agents",
      name: "agents",
      description: "87 plugins for Claude Code",
      tags: ["plugins"],
      featured: false,
      packageCount: 488,
      bundleCount: 64,
      subscribed: false,
      packages: [],
      bundles: [],
    },
    {
      repo: "acme/acme-tools",
      repoKey: "acme/acme-tools",
      name: "acme-tools",
      description: "Rust skills",
      tags: ["rust"],
      featured: false,
      packageCount: 5,
      bundleCount: 0,
      subscribed: true,
      packages: [],
      bundles: [],
    },
  ],
  fetchedAt: "2026-08-19T15:00:00Z",
  stale: false,
};

const reactHits: SkillsShHit[] = [
  {
    skill: "vercel-react-best-practices",
    repo: "vercel-labs/agent-skills",
    installs: 645_639,
  },
  {
    skill: "vercel-react-native-skills",
    repo: "vercel-labs/agent-skills",
    installs: 190_525,
  },
];

const leaderboards: Record<string, SkillsShHit[]> = {
  trending: [
    { skill: "find-skills", repo: "vercel-labs/skills", installs: 24_531 },
    ...reactHits,
  ],
  hot: [
    {
      skill: "deploy-to-vercel",
      repo: "vercel-labs/agent-skills",
      installs: 9_120,
    },
  ],
  "all-time": reactHits,
};

export const communityHandlers: Record<string, Handler> = {
  community_directory: () => directory,
  community_skillssh_available: () => true,
  community_skillssh_search: ({ query }: { query: string }) =>
    query.toLowerCase().includes("react") ? reactHits : [],
  community_skillssh_leaderboard: ({ view }: { view: string }) =>
    leaderboards[view] ?? Promise.reject(`no such view '${view}'`),
};
