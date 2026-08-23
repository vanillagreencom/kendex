// The curated sets a catalog offers under one name, as the mock world sees
// them. Split from the scope fixtures next door: those describe what each
// project declares, these describe what a catalog puts on the shelf.
import type { BundleRow } from "@/bindings";
import { ACME, GLOBAL, proj } from "./fixture-scopes";

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
