// Builds the "Personal" (global) scope's drift rows and safety findings
// from the shared data in fixture-personal.ts, so the pages that read a
// scope's safety rows have enough hooks and plugins to design at real
// scale. The ACME project's scored items live next door in
// fixture-safety-acme.ts.
import type { DriftRow, ItemSafety } from "@/bindings";
import {
  CLAUDE_HOOK_IDS,
  CLEAN_PLUGINS,
  CLEAN_SKIP_REASON,
  CLEAN_SKIP_RULES,
  HOOK_FINDING,
  UNMANAGED_SKILLS,
} from "./fixture-personal";
import { GLOBAL } from "./fixture-scopes";

const hookSafety = (name: string): ItemSafety => ({
  kind: "hook",
  name,
  harness: "claude",
  scope: GLOBAL,
  location: "",
  safety: { score: 85, deductions: [] },
  quality: null,
  findings: [HOOK_FINDING],
  skipped: [],
  ruleset: 3,
});

const cleanPluginSafety = (name: string): ItemSafety => ({
  kind: "plugin",
  name,
  harness: "claude",
  scope: GLOBAL,
  location: "",
  safety: { score: 100, deductions: [] },
  quality: null,
  findings: [],
  skipped: CLEAN_SKIP_RULES.map((rule) => ({
    rule,
    reason: CLEAN_SKIP_REASON,
  })),
  ruleset: 3,
});

export function personalSafety(): ItemSafety[] {
  return [
    ...CLAUDE_HOOK_IDS.map(hookSafety),
    ...CLEAN_PLUGINS.map(cleanPluginSafety),
  ];
}

export function personalDrift(): DriftRow[] {
  return UNMANAGED_SKILLS.map((skill) => ({
    kind: "skill",
    name: skill.name,
    harness: skill.harness,
    scope: GLOBAL,
    state: "unmanaged",
    detail: skill.path,
  }));
}
