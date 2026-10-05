// Catalog responses captured in ui-marketplaces-packages-cold-0.json from
// the evidence archive linked in the app loading performance research attached to KEN-2779.
// Split by catalog and item kind to keep fixture files below the byte ceiling.
import type { AvailablePackage, MarketplaceRow } from "@/bindings";
import agentskills from "./packages/agent-skills.json";
import agentsAgentAM from "./packages/agents-agent-a-m.json";
import agentsAgentNZ from "./packages/agents-agent-n-z.json";
import agentscommand from "./packages/agents-command.json";
import agentsskill from "./packages/agents-skill.json";
import kendex from "./packages/kendex.json";
import kendexglobal from "./packages/kendex-global.json";
import rows from "./packages/subscriptions.json";

export const packagesFixture = {
  rows,
  packages: {
    '["sub","/home/dev/dev/.worktrees/kendex/ken-2221/tmp/research/project","kendex"]':
      kendex,
    '["sub","/home/dev/dev/.worktrees/kendex/ken-2221/tmp/research/project","agent-skills"]':
      agentskills,
    '["sub","/home/dev/dev/.worktrees/kendex/ken-2221/tmp/research/project","agents"]':
      [...agentsAgentAM, ...agentsAgentNZ, ...agentscommand, ...agentsskill],
    '["sub",null,"kendex"]': kendexglobal,
  },
} as unknown as {
  rows: MarketplaceRow[];
  packages: Record<string, AvailablePackage[]>;
};
