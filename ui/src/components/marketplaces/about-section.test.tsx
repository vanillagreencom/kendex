import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { AboutView, CatalogFinding, MarketplaceMeta } from "@/bindings";
import {
  ABOUT_FINDINGS_TITLE,
  ABOUT_NOTHING_SAID,
} from "@/lib/copy-marketplaces";
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

const render = (
  view: Partial<AboutView> = {},
  meta: MarketplaceMeta | null = null,
  counts: { [key in string]: number } | null = null,
) => {
  const about: AboutView = { findings: [], updatedAt: null, ...view };
  stub.about = { [catalogKey(catalog)]: about };
  return renderToStaticMarkup(
    <AboutSection catalog={catalog} meta={meta} counts={counts} />,
  );
};

const finding: CatalogFinding = {
  location: "kendex.toml",
  problem: "no skills root",
  fix: "add one",
};

describe("the About tab as a profile", () => {
  it("shows what the catalog says about itself and when it last changed", () => {
    const html = render(
      { updatedAt: "2026-08-30T12:00:00+00:00" },
      {
        description: "Skills for shipping",
        author: "Vanilla Green",
        license: "MIT",
        homepage: "https://kendex.ai",
      },
    );
    expect(html).toContain("Skills for shipping");
    expect(html).toContain("Vanilla Green");
    expect(html).toContain("MIT");
    // A link, not just the string: ExternalLink renders the URL as its own
    // child text, so the text alone passes for a plain span too.
    expect(html).toMatch(/<button[^>]*>https:\/\/kendex\.ai<\/button>/);
    expect(html).toContain("2026-08-30T12:00:00+00:00");
  });

  // The engine's own per-kind map, not a total summed here from the About
  // report's per-root rows — that report counts a name once per declared
  // root, and this line has to agree with the Packages tab beside it.
  it("names what it holds from the counts the engine shipped", () => {
    const html = render({}, null, { skill: 42, agent: 1 });
    // The app's kind order, which puts agents before skills — not the
    // wire map's alphabetical one, and not the order they were passed in.
    expect(html).toContain("1 agent and 42 skills");
  });

  it("leaves the row out when nothing has counted the catalog yet", () => {
    const html = render({}, null, null);
    expect(html).not.toContain("Contains");
  });

  // The tags, the reading mode and the per-root table were an engineer's
  // account of kendex's own work. The payload no longer carries the last
  // two at all; the header says the tags once.
  it("says nothing about how kendex read the catalog", () => {
    const html = render({}, { tags: ["review"] }, { skill: 3 });
    expect(html).not.toContain("kendex.toml");
    expect(html).not.toContain("review");
    expect(html).not.toContain(">skills<");
  });

  it("has nothing to show for a catalog that declares nothing", () => {
    expect(render()).toContain(ABOUT_NOTHING_SAID);
  });
});

describe("the About tab's findings section", () => {
  it("lists what the catalog gets wrong", () => {
    const html = render({ findings: [finding] });
    expect(html).toContain(ABOUT_FINDINGS_TITLE);
    expect(html).toContain("no skills root");
  });

  it("is absent, and says nothing in its place, with no findings", () => {
    const html = render({}, null, { skill: 3 });
    expect(html).not.toContain(ABOUT_FINDINGS_TITLE);
    expect(html).not.toContain("Nothing wrong");
  });
});
