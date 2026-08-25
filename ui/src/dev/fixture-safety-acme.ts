// The ACME project's scored items: one skill with a critical finding, one
// skill scored for two tools at once, and a config-entry kind — enough
// shapes to design a warning list against.
import type { Finding, HarnessId, ItemSafety } from "@/bindings";
import { FIXTURE_RULESET } from "./fixture-safety";
import { ACME, proj } from "./fixture-scopes";

const SCRAPER_FINDINGS: Finding[] = [
  {
    rule: "credential-theft",
    severity: "critical",
    location: "SKILL.md:12",
    message: "reads a credential file and sends it to a remote host",
    remediation:
      "remove the line that uploads the file, or install this skill only if you trust its source",
  },
  {
    rule: "dangerous-commands",
    severity: "high",
    location: "SKILL.md:20",
    message: "runs a shell command that deletes files without asking",
    remediation: "scope the command to a specific path, or drop it",
  },
];

const scraperSafety = (): ItemSafety => ({
  kind: "skill",
  name: "scraper",
  harness: "claude",
  scope: proj(ACME),
  location: "",
  safety: { score: 50, deductions: [] },
  quality: null,
  findings: SCRAPER_FINDINGS,
  skipped: [],
  ruleset: FIXTURE_RULESET,
});

// kendex keeps the same skill directory symlinked for every harness that
// declares it, so a skill installed for both Codex and Pi reads the exact
// same bytes and trips the exact same findings on both. One rule fires at
// four call sites in the skill's own files, plus one distinct finding, to
// match how this actually shows up at real scale.
const VISUAL_QA_PATH = `${ACME}/.claude/skills/visual-qa`;
const VISUAL_QA_RULE_LOCATIONS = [
  `${VISUAL_QA_PATH}/evals/grade.py:848`,
  `${VISUAL_QA_PATH}/evals/grade.py:950`,
  `${VISUAL_QA_PATH}/process.py:89`,
  `${VISUAL_QA_PATH}/process.py:111`,
];
const VISUAL_QA_FINDINGS: Finding[] = [
  ...VISUAL_QA_RULE_LOCATIONS.map(
    (location): Finding => ({
      rule: "dangerous-commands",
      severity: "high",
      location,
      message: "runs a shell command built from unescaped input",
      remediation: "validate or escape the input before it reaches the shell",
    }),
  ),
  {
    rule: "rce",
    severity: "critical",
    location: `${VISUAL_QA_PATH}/evals/grade.py:12`,
    message: "downloads a script from a URL and executes it directly",
    remediation: "pin and vendor the script instead of fetching it at runtime",
  },
];

const visualQaSafety = (harness: HarnessId): ItemSafety => ({
  kind: "skill",
  name: "visual-qa",
  harness,
  scope: proj(ACME),
  location: "",
  safety: { score: 30, deductions: [] },
  quality: null,
  findings: VISUAL_QA_FINDINGS,
  skipped: [],
  ruleset: FIXTURE_RULESET,
});

const METRICS_RELAY_FINDINGS: Finding[] = [
  {
    rule: "broad-permissions",
    severity: "high",
    location: ".mcp.json:5",
    message: "requests filesystem access far beyond what it declares using",
    remediation: "narrow the requested scope, or drop it if it's unused",
  },
];

const metricsRelaySafety = (): ItemSafety => ({
  kind: "mcp-server",
  name: "metrics-relay",
  harness: "claude",
  scope: proj(ACME),
  location: "",
  safety: { score: 58, deductions: [] },
  quality: null,
  findings: METRICS_RELAY_FINDINGS,
  skipped: [],
  ruleset: FIXTURE_RULESET,
});

export function acmeSafety(): ItemSafety[] {
  return [
    scraperSafety(),
    visualQaSafety("codex"),
    visualQaSafety("pi"),
    metricsRelaySafety(),
  ];
}
