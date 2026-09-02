// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { AvailablePackage, Finding, PackageSafety } from "@/bindings";
import {
  SAFETY_CAVEAT,
  SAFETY_DOT_UNCHECKED,
  safetyDotWords,
} from "@/lib/copy-safety";
import { subscription } from "@/stores/marketplaces-shared";
import { useNavStore } from "@/stores/nav";
import { safetyKey } from "@/stores/preinstall-safety";
import { mount as mountTree } from "@/test/dom";
import { PackagesTable } from "./packages-table";

// Static rendering reads a zustand store's initial snapshot, so the score
// store's hook is wrapped to let each test seed the row's score.
const stub = vi.hoisted(() => ({ scores: {} as Record<string, unknown> }));
vi.mock("@/stores/preinstall-safety", async (importOriginal) => {
  const mod =
    await importOriginal<typeof import("@/stores/preinstall-safety")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.usePreinstallSafety.getState(),
      scores: stub.scores,
      // A mounted row runs the effect that queues a score, and there is no
      // backend behind these tests to answer it.
      want: () => {},
    };
    return selector ? selector(state) : state;
  };
  return {
    ...mod,
    usePreinstallSafety: Object.assign(hook, mod.usePreinstallSafety),
  };
});

const catalog = subscription({ scope: "global" }, "kendex");

const row: AvailablePackage = {
  kind: "skill",
  name: "gh",
  description: null,
  summary: null,
  tags: [],
  bundles: [],
  dependencies: { required: [], optional: [] },
  state: "available",
  collision: null,
};

const FINDING: Finding = {
  rule: "dangerous-commands",
  severity: "high",
  location: "SKILL.md",
  line: 3,
  message: "runs a shell command that deletes files without asking",
  remediation: "scope the command to a specific path, or drop it",
};

const scored = (score: number, findings: Finding[] = []): PackageSafety => ({
  kind: "skill",
  name: "gh",
  findings,
  safety: { score, deductions: [] },
  quality: null,
  skipped: [],
  notes: [],
  contentHash: "abc",
  ruleset: 1,
  fromCache: false,
});

const render = (safety: PackageSafety | null) => {
  stub.scores = safety ? { [safetyKey(catalog, "skill", "gh")]: safety } : {};
  return renderToStaticMarkup(
    <PackagesTable entries={[{ catalog, row }]} showMarketplace={false} />,
  );
};

// What the dot's words are attached to. A tooltip popup is portalled and
// only mounts once open, so the trigger's own contents are the whole of
// what a reader gets without a pointer.
const trigger = (html: string): string =>
  html.match(
    /<button[^>]*data-slot="tooltip-trigger"[^>]*>(.*?)<\/button>/,
  )?.[1] ?? "";

// The description is the agent's load trigger; the row is for a person, so
// it shows the summary and never the trigger beside it.
describe("the line under the package name", () => {
  it("is the summary, not the description", () => {
    stub.scores = {};
    const html = renderToStaticMarkup(
      <PackagesTable
        entries={[
          {
            catalog,
            row: {
              ...row,
              description: "Load to work a pull request.",
              summary: "Threads, reviews, CI logs, merges.",
            },
          },
        ]}
        showMarketplace={false}
      />,
    );
    expect(html).toContain("Threads, reviews, CI logs, merges.");
    expect(html).not.toContain("Load to work a pull request.");
  });
});

describe("the safety dot in the packages list", () => {
  it("carries the caveat beside the number, since this row installs here", () => {
    const html = render(scored(100));
    expect(html).toContain(">Install<");
    expect(trigger(html)).toContain("100/100.");
    expect(trigger(html)).toContain(SAFETY_CAVEAT);
  });

  it("says the same for a score with findings behind it", () => {
    const html = render(scored(60, [FINDING]));
    expect(trigger(html)).toContain("60/100.");
    expect(trigger(html)).toContain(SAFETY_CAVEAT);
  });

  it("names the worst severity in words, so the colour is never alone", () => {
    const html = render(
      scored(40, [FINDING, { ...FINDING, severity: "critical" }]),
    );
    expect(trigger(html)).toContain("Serious · 40/100.");
  });

  it("puts the words where a keyboard reaches them, not on hover alone", () => {
    // A tab stop before Install, and text in the row rather than a native
    // `title` — which a screen reader may skip and a keyboard never lands on.
    const html = render(scored(100));
    expect(trigger(html)).toContain(
      `<span class="sr-only">${safetyDotWords(100, 0, [])}</span>`,
    );
    expect(html.indexOf(SAFETY_CAVEAT)).toBeLessThan(html.indexOf(">Install<"));
    expect(html).not.toContain(`title="${safetyDotWords(100, 0, [])}`);
  });

  it("says no result has landed, and still claims nothing either way", () => {
    // Scores queue one at a time and a failed read leaves a row without
    // one, so this state is what an installable row often looks like. The
    // caveat has to reach the reader here too, and no score may.
    const html = render(null);
    expect(html).toContain(">Install<");
    expect(trigger(html)).toContain("Not checked yet.");
    expect(trigger(html)).toContain(SAFETY_CAVEAT);
    expect(trigger(html)).toContain(SAFETY_DOT_UNCHECKED);
    expect(trigger(html)).not.toMatch(/\d+\/100/);
    expect(html.indexOf(SAFETY_DOT_UNCHECKED)).toBeLessThan(
      html.indexOf(">Install<"),
    );
  });
});

// The activation tests need a live DOM: whether a click reaches the row is a
// question about event propagation, which static markup cannot answer.
const mount = (safety: PackageSafety | null) => {
  stub.scores = safety ? { [safetyKey(catalog, "skill", "gh")]: safety } : {};
  const goToAvailablePackage = vi.fn();
  useNavStore.setState({ goToAvailablePackage });
  const host = mountTree(
    <PackagesTable entries={[{ catalog, row }]} showMarketplace={false} />,
  );
  const dot = host.querySelector<HTMLButtonElement>(
    '[data-slot="tooltip-trigger"]',
  );
  if (!dot) throw new Error("no safety trigger rendered");
  return { host, dot, goToAvailablePackage };
};

describe("reading the safety dot", () => {
  it("does not open the package page on a click", async () => {
    const { dot, goToAvailablePackage } = mount(scored(60, [FINDING]));
    await userEvent.click(dot);
    expect(goToAvailablePackage).not.toHaveBeenCalled();
  });

  it("does not open the package page on Enter or Space", async () => {
    // The browser turns both into a click on the button, which is the path
    // the row would otherwise navigate on.
    const { dot, goToAvailablePackage } = mount(scored(60, [FINDING]));
    dot.focus();
    await userEvent.keyboard("{Enter}");
    await userEvent.keyboard(" ");
    expect(goToAvailablePackage).not.toHaveBeenCalled();
  });

  it("does not open it while the score is still being read", async () => {
    const { dot, goToAvailablePackage } = mount(null);
    dot.focus();
    await userEvent.click(dot);
    await userEvent.keyboard("{Enter}");
    expect(goToAvailablePackage).not.toHaveBeenCalled();
  });

  it("still shows the words when the trigger takes focus", () => {
    // The popup is portalled out of the row, so it is the document's to find
    // — and the trigger's own sr-only copy must not stand in for it.
    const { dot } = mount(scored(60, [FINDING]));
    expect(document.querySelector('[data-slot="tooltip-content"]')).toBeNull();
    act(() => dot.focus());
    expect(
      document.querySelector('[data-slot="tooltip-content"]')?.textContent,
    ).toContain(SAFETY_CAVEAT);
  });

  it("does not open the package page from the popup's own words", async () => {
    // The popup is drawn outside the row, but React still routes its clicks
    // through the row, so reading the caveat there must stay a read.
    const { dot, goToAvailablePackage } = mount(scored(60, [FINDING]));
    act(() => dot.focus());
    const popup = document.querySelector<HTMLElement>(
      '[data-slot="tooltip-content"]',
    );
    if (!popup) throw new Error("no tooltip popup rendered");
    await userEvent.click(popup);
    expect(goToAvailablePackage).not.toHaveBeenCalled();
  });

  it("still opens the package page from the rest of the row", async () => {
    const { host, goToAvailablePackage } = mount(scored(60, [FINDING]));
    const name = host.querySelector("td");
    if (!name) throw new Error("no row cell rendered");
    await userEvent.click(name);
    expect(goToAvailablePackage).toHaveBeenCalledWith({
      catalog,
      kind: "skill",
      name: "gh",
    });
  });
});
