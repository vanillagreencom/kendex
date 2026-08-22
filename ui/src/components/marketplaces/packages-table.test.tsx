import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { AvailablePackage, PackageSafety, Verdict } from "@/bindings";
import { PREINSTALL_SAFETY_CAVEAT } from "@/lib/copy-safety";
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

describe("the safety dot in the packages list", () => {
  it("carries the caveat beside the number, since this row installs here", () => {
    const html = render(scored("clean", 100));
    expect(html).toContain(">Install<");
    expect(html).toContain("Nothing found · 100/100.");
    expect(html).toContain(PREINSTALL_SAFETY_CAVEAT);
  });

  it("says the same for a verdict that is not clean", () => {
    const html = render(scored("warn", 60));
    expect(html).toContain("Installs, with a warning");
    expect(html).toContain(PREINSTALL_SAFETY_CAVEAT);
  });

  it("claims nothing while the score is still being read", () => {
    const html = render(null);
    expect(html).toContain('title="Checking…"');
    expect(html).not.toContain(PREINSTALL_SAFETY_CAVEAT);
  });
});
