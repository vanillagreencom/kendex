// A marketplace package's safety report, shown before it is installed: one
// package in the kendex catalog scores with findings, everything else is
// clean. Installed items are scored elsewhere, in fixture-safety.ts.
import type { ItemKind, PackageSafety } from "@/bindings";

const CLEAN_SAFETY = (kind: ItemKind, name: string): PackageSafety => ({
  kind,
  name,
  findings: [],
  safety: { score: 100, deductions: [] },
  quality: null,
  skipped: [],
  verdict: "clean",
  reasons: [],
  contentHash: "b3a19f04c7d2e851",
  ruleset: 3,
  fromCache: true,
  settled: [],
  publisher: null,
});

const WEBHOOK_SAFETY: PackageSafety = {
  kind: "skill",
  name: "webhook-relay",
  findings: [
    {
      rule: "network-exfiltration",
      severity: "high",
      location: "skills/webhook-relay/SKILL.md:24",
      message: "posts file contents to an address the skill itself chooses",
      remediation: "pin the destination and show it to the user before sending",
    },
    {
      rule: "credential-theft",
      severity: "medium",
      location: "skills/webhook-relay/relay.sh:9",
      message: "reads GITHUB_TOKEN and forwards it with the request",
      remediation:
        "drop the token from the request; the webhook does not need it",
    },
  ],
  safety: {
    score: 72,
    deductions: [
      {
        rule: "network-exfiltration",
        location: "skills/webhook-relay/SKILL.md:24",
        severity: "high",
        points: 20,
        repeat: false,
      },
      {
        rule: "credential-theft",
        location: "skills/webhook-relay/relay.sh:9",
        severity: "medium",
        points: 8,
        repeat: false,
      },
    ],
  },
  quality: null,
  skipped: [],
  verdict: "warn",
  reasons: ["safety 72 is below the warn threshold 80"],
  contentHash: "e0c574a2918bd63f",
  ruleset: 3,
  fromCache: false,
  // The publisher settled the second one; the first is still an open
  // question and still counts.
  settled: [
    null,
    {
      reason: "intended",
      dismissedAt: "2026-08-19T09:12:00Z",
      occurrences: 1,
    },
  ],
  publisher: "vanillagreencom/kendex",
};

export const packageSafety = (kind: ItemKind, name: string): PackageSafety =>
  kind === "skill" && name === "webhook-relay"
    ? WEBHOOK_SAFETY
    : CLEAN_SAFETY(kind, name);
