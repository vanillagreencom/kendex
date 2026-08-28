// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { afterEach, describe, expect, it, vi } from "vitest";
import { commands, type MineRow, type StatusFinding } from "@/bindings";
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

const mounted: Root[] = [];
afterEach(() => {
  act(() => {
    for (const root of mounted) root.unmount();
  });
  mounted.length = 0;
  document.body.replaceChildren();
  vi.mocked(commands.openInEditor).mockReset();
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

describe("a finding's place on a Mine row", () => {
  // The reader needs the line; Open needs a path. Those are two jobs, and
  // a location spelled `file:line` cannot do both — `open_in_editor` gets
  // a path with a line stuck to it and finds no such file.
  it("shows the line and opens the file without it", async () => {
    const host = document.body.appendChild(document.createElement("div"));
    const root = createRoot(host);
    mounted.push(root);
    act(() => root.render(card([finding("low", "prints a token")])));
    const toggle = Array.from(host.querySelectorAll("button")).find((button) =>
      button.textContent?.includes("1 finding"),
    );
    if (!toggle) throw new Error("no findings toggle rendered");
    await userEvent.click(toggle);

    expect(host.textContent).toContain("skills/gh/SKILL.md:12");
    const open = Array.from(host.querySelectorAll("button")).find(
      (button) => button.textContent === "Open",
    );
    if (!open) throw new Error("no Open button rendered");
    await userEvent.click(open);
    expect(commands.openInEditor).toHaveBeenCalledWith(
      "/home/jane/dev/team-skills/skills/gh/SKILL.md",
    );
  });

  it("shows the path alone where the finding has no line", async () => {
    const host = document.body.appendChild(document.createElement("div"));
    const root = createRoot(host);
    mounted.push(root);
    act(() =>
      root.render(card([{ ...finding("low", "prints a token"), line: null }])),
    );
    const toggle = Array.from(host.querySelectorAll("button")).find((button) =>
      button.textContent?.includes("1 finding"),
    );
    if (!toggle) throw new Error("no findings toggle rendered");
    await userEvent.click(toggle);
    expect(host.textContent).toContain("skills/gh/SKILL.md");
    expect(host.textContent).not.toContain("skills/gh/SKILL.md:");
  });
});
