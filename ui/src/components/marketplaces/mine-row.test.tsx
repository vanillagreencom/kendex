// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { renderToStaticMarkup } from "react-dom/server";
import { afterEach, describe, expect, it, vi } from "vitest";
import { commands, type MineRow, type StatusFinding } from "@/bindings";
import { mount } from "@/test/dom";
import { MineRowCard } from "./mine-row";

vi.mock("@/bindings", () => ({ commands: { openInEditor: vi.fn() } }));

const finding = (severity: string, message: string): StatusFinding => ({
  file: "skills/gh/SKILL.md",
  line: 12,
  kind: "skill",
  name: "gh",
  pass: "safety",
  severity,
  message,
  fix: "drop it",
});

const row = (findings: StatusFinding[]): MineRow => ({
  path: "/home/jane/dev/team-skills",
  name: "team-skills",
  description: null,
  license: "MIT",
  counts: { skill: 1 },
  bundles: 0,
  declared: true,
  breakage: 0,
  advisory: 0,
  safetyFindings: findings.length,
  findings,
  git: {
    repository: false,
    clean: null,
    remote: null,
    candidate: null,
    ahead: null,
  },
});

const card = (findings: StatusFinding[]) => (
  <MineRowCard
    row={row(findings)}
    submission={null}
    onImport={() => {}}
    onSubmit={() => {}}
  />
);

afterEach(() => vi.mocked(commands.openInEditor).mockReset());

describe("severity on a Mine row", () => {
  // Severity is never conveyed by implication or colour alone: the badge
  // leads with the worst finding's word, and each expanded finding says its
  // own beside the message.
  it("leads the badge with the worst finding's severity", () => {
    const html = renderToStaticMarkup(
      card([
        finding("low", "prints a token"),
        finding("critical", "pipes curl to sh"),
      ]),
    );
    expect(html).toContain("Serious · 2 findings");
  });

  it("says each expanded finding's severity in words, and they differ", async () => {
    const host = mount(
      card([
        finding("low", "prints a token"),
        finding("critical", "pipes curl to sh"),
      ]),
    );
    const toggle = Array.from(host.querySelectorAll("button")).find((button) =>
      button.textContent?.includes("2 findings"),
    );
    if (!toggle) throw new Error("no findings toggle rendered");
    await userEvent.click(toggle);
    expect(host.textContent).toContain("Serious: pipes curl to sh");
    expect(host.textContent).toContain("Minor: prints a token");
  });
});

describe("a finding's place on a Mine row", () => {
  it("shows the source line when present and opens only the file path", async () => {
    const rows = [
      {
        name: "a finding with a line",
        line: 12,
        location: "skills/gh/SKILL.md:12",
      },
      {
        name: "a finding without a line",
        line: null,
        location: "skills/gh/SKILL.md",
      },
    ];
    expect(rows).toHaveLength(2);
    for (const row of rows) {
      const host = mount(
        card([{ ...finding("low", "prints a token"), line: row.line }]),
      );
      const toggle = Array.from(host.querySelectorAll("button")).find(
        (button) => button.textContent?.includes("1 finding"),
      );
      if (!toggle) throw new Error("no findings toggle rendered");
      await userEvent.click(toggle);
      expect(host.textContent, row.name).toContain(row.location);
      if (row.line === null) {
        expect(host.textContent).not.toContain("skills/gh/SKILL.md:");
      } else {
        const open = Array.from(host.querySelectorAll("button")).find(
          (button) => button.textContent === "Open",
        );
        if (!open) throw new Error("no Open button rendered");
        await userEvent.click(open);
        expect(commands.openInEditor).toHaveBeenCalledWith(
          "/home/jane/dev/team-skills/skills/gh/SKILL.md",
        );
      }
    }
  });
});
