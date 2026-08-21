// Builds the "Personal" (global) scope's drift rows and safety findings
// from the shared data in fixture-personal.ts, so the Review page has enough
// hooks and plugins to design triage at real scale. The ACME project's
// blocked items live next door in fixture-safety-acme.ts.
import type { DriftRow, ItemSafety } from "@/bindings";
import { decisionsFor } from "./fixture-decisions";
import {
  CLAUDE_HOOK_IDS,
  CLEAN_PLUGINS,
  CLEAN_SKIP_REASON,
  CLEAN_SKIP_RULES,
  HOOK_FINDING,
  UNMANAGED_SKILLS,
} from "./fixture-personal";
import { GLOBAL } from "./fixture-scopes";

const hookSafety = (name: string, index: number): ItemSafety => ({
  kind: "hook",
  name,
  harness: "claude",
  scope: GLOBAL,
  safety: { score: 85, deductions: [] },
  quality: null,
  findings: [HOOK_FINDING],
  skipped: [],
  verdict: "warn",
  reasons: [
    "A high-severity finding is worth a warning, though not enough on its own to hold this back.",
  ],
  contentHash: `hook-${index}`,
  reviewHash: `hook-${index}`,
  location: "",
  provenance: null,
  decisions: decisionsFor(`hook:${name}:claude`, `hook-${index}`, [
    HOOK_FINDING,
  ]),
  override: { state: "absent" },
});

const cleanPluginSafety = (name: string, index: number): ItemSafety => ({
  kind: "plugin",
  name,
  harness: "claude",
  scope: GLOBAL,
  safety: { score: 100, deductions: [] },
  quality: null,
  findings: [],
  skipped: CLEAN_SKIP_RULES.map((rule) => ({
    rule,
    reason: CLEAN_SKIP_REASON,
  })),
  verdict: "clean",
  reasons: ["Nothing found, though its own files could not be read yet."],
  contentHash: `clean-plugin-${index}`,
  reviewHash: `clean-plugin-${index}`,
  location: "",
  provenance: null,
  decisions: [],
  override: { state: "absent" },
});

// A skill whose publisher named the flag it exists to guard against, and
// recorded why. Nothing here needs a decision — the point is that the
// person can still read what was decided on their behalf, and by whom.
const PUBLISHER_SETTLED: ItemSafety = {
  kind: "skill",
  name: "growth-guards",
  harness: "claude",
  scope: GLOBAL,
  safety: { score: 100, deductions: [] },
  quality: null,
  findings: [
    {
      rule: "safety-bypass",
      severity: "critical",
      location: "~/.agents/skills/growth-guards/SKILL.md:69",
      message: "`--no-verify` skips the checks a commit runs",
      remediation:
        "leave the check in place and let the user answer for themselves",
    },
  ],
  skipped: [],
  verdict: "clean",
  reasons: [],
  contentHash: "growth-guards",
  reviewHash: "growth-guards",
  location: "",
  provenance: "vanillagreencom/kendex",
  decisions: [
    {
      fingerprint: "f2c72fb521054194",
      token: null,
      state: {
        state: "author-dismissed",
        reason: "intended",
        dismissedAt: "2026-08-19T09:12:00Z",
        publisher: "vanillagreencom/kendex",
      },
    },
  ],
  override: { state: "absent" },
};

export function personalSafety(): ItemSafety[] {
  return [
    ...CLAUDE_HOOK_IDS.map(hookSafety),
    ...CLEAN_PLUGINS.map(cleanPluginSafety),
    PUBLISHER_SETTLED,
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
