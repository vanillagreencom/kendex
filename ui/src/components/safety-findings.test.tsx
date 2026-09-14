// @vitest-environment jsdom

import userEvent from "@testing-library/user-event";
import { act } from "react";
import { describe, expect, it } from "vitest";
import type { Finding } from "@/bindings";
import { TooltipProvider } from "@/components/ui/tooltip";
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
        const hidden = [...host.querySelectorAll(".sr-only")];
        expect(hidden.map((el) => el.textContent).join("")).not.toContain(
          row.word,
        );
      }
    }
  });
});

describe("a finding's file link", () => {
  // One button opens the menu and names the whole path on hover, and the
  // path's tooltip never stands over the open menu.
  it("opens its menu from the keyboard with no tooltip over it", async () => {
    const host = mount(
      <TooltipProvider>
        <FindingLine finding={finding("low")} />
      </TooltipProvider>,
    );
    const buttons = host.querySelectorAll("button");
    expect(buttons).toHaveLength(1);
    act(() => buttons[0].focus());
    await userEvent.keyboard("{Enter}");
    act(() => {
      buttons[0].dispatchEvent(new MouseEvent("mouseenter", { bubbles: true }));
    });
    expect(document.querySelectorAll('[role="menuitem"]')).toHaveLength(3);
    expect(document.querySelector('[data-slot="tooltip-content"]')).toBeNull();
  });
});
