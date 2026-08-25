import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { Finding } from "@/bindings";
import { FindingLine } from "./safety-findings";

const finding = (severity: Finding["severity"]): Finding => ({
  rule: "dangerous-commands",
  severity,
  location: "SKILL.md:3",
  message: "runs a shell command that deletes files without asking",
  remediation: "scope the command to a specific path, or drop it",
});

describe("a finding's severity word", () => {
  it("is visible text, distinct per severity — never the dot's colour alone", () => {
    const critical = renderToStaticMarkup(
      <FindingLine finding={finding("critical")} />,
    );
    const low = renderToStaticMarkup(<FindingLine finding={finding("low")} />);
    expect(critical).toContain("Serious:");
    expect(low).toContain("Minor:");
    expect(critical).not.toContain("Minor:");
    expect(low).not.toContain("Serious:");
    // Visible beside the message, not tucked into a reader-only span.
    expect(critical).not.toContain("sr-only");
  });
});
