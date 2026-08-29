import type { Scope } from "@/bindings";

export const ACME = "/home/dana/work/acme-web";
export const API = "/home/dana/work/api-server";

export const AVAILABLE_SKILLS = [
  "code-review",
  "deploy",
  "docs",
  "github",
  "release-notes",
  "tests",
];

/** What the catalog gives each agent while nothing is chosen for it —
 *  the lock's record, which the dev shell has no engine to write. */
export const AUTOMATIC_SKILLS: Record<string, string[]> = {
  orch: ["deploy", "github", "release-notes"],
  reviewer: ["code-review", "tests"],
};

export const GLOBAL: Scope = { scope: "global" };
export const proj = (root: string): Scope => ({ scope: "project", root });
