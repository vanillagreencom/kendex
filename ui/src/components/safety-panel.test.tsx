import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { AuditResult, Finding, Severity } from "@/bindings";
import { SAFETY_CAVEAT } from "@/lib/copy-safety";
import { SEVERITY_LABELS } from "@/lib/labels";
import { SafetyPanel } from "./safety-panel";

const finding = (severity: Severity, location: string): Finding => ({
  rule: "dangerous-commands",
  severity,
  location,
  message: "runs a shell command that deletes files without asking",
  remediation: "scope the command to a specific path, or drop it",
});

const result = (over: Partial<AuditResult> = {}): AuditResult => ({
  findings: [],
  skipped: [],
  safety: { score: 100, deductions: [] },
  quality: null,
  ruleset: 3,
  ...over,
});

const render = (over?: Partial<AuditResult>, notes?: string[]) =>
  renderToStaticMarkup(<SafetyPanel result={result(over)} notes={notes} />);

describe("the safety block", () => {
  it("says the score in words, not only inside the circle", () => {
    // The disc is decorative, so a reader who never sees it still gets the
    // number — and the caveat that says what the number is a reading of.
    const html = render({ safety: { score: 62, deductions: [] } });
    expect(html).toContain("62/100");
    expect(html).toContain(SAFETY_CAVEAT);
    expect(html.indexOf("62/100")).toBeLessThan(html.indexOf(SAFETY_CAVEAT));
  });

  it("names the worst severity as a word, never colour alone", () => {
    const html = render({
      safety: { score: 40, deductions: [] },
      findings: [finding("low", "SKILL.md:2"), finding("critical", "run.sh:9")],
    });
    expect(html).toContain(SEVERITY_LABELS.critical);
    expect(html).toContain("2 findings");
  });

  it("lists every finding with the file and line it fired at", () => {
    const html = render({
      findings: [finding("high", "SKILL.md:20"), finding("high", "run.sh:4")],
    });
    expect(html).toContain("SKILL.md:20");
    expect(html).toContain("run.sh:4");
  });

  it("says nothing was found rather than falling silent on a clean read", () => {
    expect(render()).toContain("Nothing found");
  });

  it("says what a partial read means instead of claiming a clean one", () => {
    const html = render({
      skipped: [{ rule: "rce", reason: "the tree was too large to read" }],
    });
    expect(html).toContain("Nothing found in what was read");
  });

  it("carries what a preview did not account for", () => {
    expect(render(undefined, ["Only the first 40 files were read."])).toContain(
      "Only the first 40 files were read.",
    );
  });

  // Nothing on this block asks for an answer: the score is advisory, and a
  // fix line would make a matched pattern read as an instruction.
  it("offers no verdict to give and no fix to follow", () => {
    const html = render({ findings: [finding("critical", "run.sh:9")] });
    expect(html).not.toContain("scope the command to a specific path");
    // "not a review" in the caveat is the only place the word may appear:
    // it says what the check is, not something the reader has to do.
    expect(html).not.toMatch(/dismiss|\baccept\b|\bignore\b/i);
  });
});
