import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { AboutView, CatalogFinding } from "@/bindings";
import { CATALOG_LAYOUT_CLEAN } from "@/lib/copy-safety";
import { catalogKey, subscription } from "@/stores/marketplaces-shared";
import { AboutSection } from "./about-section";

// Static rendering reads a zustand store's initial snapshot, so the store
// hook is wrapped to let each test seed the report this tab shows.
const stub = vi.hoisted(() => ({ about: {} as Record<string, unknown> }));
vi.mock("@/stores/marketplaces", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/marketplaces")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = { ...mod.useMarketplacesStore.getState(), about: stub.about };
    return selector ? selector(state) : state;
  };
  return {
    ...mod,
    useMarketplacesStore: Object.assign(hook, mod.useMarketplacesStore),
  };
});

const catalog = subscription({ scope: "global" }, "kendex");

const render = (findings: CatalogFinding[]) => {
  const about: AboutView = { mode: "explicit", found: [], findings };
  stub.about = { [catalogKey(catalog)]: about };
  return renderToStaticMarkup(<AboutSection catalog={catalog} meta={null} />);
};

describe("the About tab with nothing to report", () => {
  it("clears the catalog's layout, never the packages in it", () => {
    expect(render([])).toContain(CATALOG_LAYOUT_CLEAN);
  });

  it("shows the findings instead when the catalog has any", () => {
    const html = render([
      { location: "kendex.toml", problem: "no skills root", fix: "add one" },
    ]);
    expect(html).toContain("no skills root");
    expect(html).not.toContain(CATALOG_LAYOUT_CLEAN);
  });
});
