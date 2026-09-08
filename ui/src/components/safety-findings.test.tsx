// @vitest-environment jsdom

import { describe, expect, it } from "vitest";
import type { Finding } from "@/bindings";
import { mount } from "@/test/dom";
import { FindingLine } from "./safety-findings";

const finding = (severity: Finding["severity"]): Finding => ({
  rule: "dangerous-commands",
  severity,
  location: "SKILL.md",
  line: 3,
  message: "runs a shell command that deletes files without asking",
  remediation: "scope the command to a specific path, or drop it",
});

describe("a finding's severity word", () => {
  it("puts distinct severity words beside the message, beyond the dot's title", () => {
    const rows = [
      { severity: "critical" as const, word: "Serious:", other: "Minor:" },
      { severity: "low" as const, word: "Minor:", other: "Serious:" },
    ];
    expect(rows).toHaveLength(2);
    for (const row of rows) {
      const host = mount(<FindingLine finding={finding(row.severity)} />);
      const words = host.querySelector("p > span");
      expect(words?.textContent?.trim(), row.severity).toBe(row.word);
      expect(host.innerHTML, row.severity).not.toContain(row.other);
      if (row.severity === "critical") {
        expect(host.innerHTML).not.toContain("sr-only");
      }
    }
  });
});
