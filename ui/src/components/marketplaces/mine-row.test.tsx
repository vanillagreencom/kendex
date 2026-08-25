// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { afterEach, describe, expect, it } from "vitest";
import type { MineRow, StatusFinding } from "@/bindings";
import { MineRowCard } from "./mine-row";

const finding = (severity: string, message: string): StatusFinding => ({
  file: "skills/gh/SKILL.md",
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

const mounted: Root[] = [];
afterEach(() => {
  act(() => {
    for (const root of mounted) root.unmount();
  });
  mounted.length = 0;
  document.body.replaceChildren();
});

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
    const host = document.body.appendChild(document.createElement("div"));
    const root = createRoot(host);
    mounted.push(root);
    act(() =>
      root.render(
        card([
          finding("low", "prints a token"),
          finding("critical", "pipes curl to sh"),
        ]),
      ),
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
