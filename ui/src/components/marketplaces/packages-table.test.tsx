import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { AvailablePackage, PackageSafety, Verdict } from "@/bindings";
import { PREINSTALL_SAFETY_CAVEAT, safetyDotWords } from "@/lib/copy-safety";
import { subscription } from "@/stores/marketplaces-shared";
import { safetyKey } from "@/stores/preinstall-safety";
import { PackagesTable } from "./packages-table";

// Static rendering reads a zustand store's initial snapshot, so the score
// store's hook is wrapped to let each test seed the row's verdict.
const stub = vi.hoisted(() => ({ scores: {} as Record<string, unknown> }));
vi.mock("@/stores/preinstall-safety", async (importOriginal) => {
  const mod =
    await importOriginal<typeof import("@/stores/preinstall-safety")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.usePreinstallSafety.getState(),
      scores: stub.scores,
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
  tags: [],
  bundles: [],
  state: "available",
  collision: null,
};

const scored = (verdict: Verdict, score: number): PackageSafety => ({
  kind: "skill",
  name: "gh",
  findings: [],
  safety: { score, deductions: [] },
  quality: null,
  skipped: [],
  verdict,
  reasons: [],
  contentHash: "abc",
  ruleset: 1,
  fromCache: false,
  publisher: null,
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

describe("the safety dot in the packages list", () => {
  it("carries the caveat beside the number, since this row installs here", () => {
    const html = render(scored("clean", 100));
    expect(html).toContain(">Install<");
    expect(trigger(html)).toContain("Nothing found · 100/100.");
    expect(trigger(html)).toContain(PREINSTALL_SAFETY_CAVEAT);
  });

  it("says the same for a verdict that is not clean", () => {
    const html = render(scored("warn", 60));
    expect(trigger(html)).toContain("Installs, with a warning");
    expect(trigger(html)).toContain(PREINSTALL_SAFETY_CAVEAT);
  });

  it("puts the words where a keyboard reaches them, not on hover alone", () => {
    // A tab stop before Install, and text in the row rather than a native
    // `title` — which a screen reader may skip and a keyboard never lands on.
    const html = render(scored("clean", 100));
    expect(trigger(html)).toContain(
      `<span class="sr-only">${safetyDotWords("clean", 100)}</span>`,
    );
    expect(html.indexOf(PREINSTALL_SAFETY_CAVEAT)).toBeLessThan(
      html.indexOf(">Install<"),
    );
    expect(html).not.toContain(`title="${safetyDotWords("clean", 100)}`);
  });

  it("claims nothing while the score is still being read", () => {
    const html = render(null);
    expect(trigger(html)).toContain("Checking…");
    expect(html).not.toContain(PREINSTALL_SAFETY_CAVEAT);
  });
});
