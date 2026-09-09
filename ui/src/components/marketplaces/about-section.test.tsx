import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type {
  AboutView,
  CatalogFinding,
  MarketplaceMeta,
  MarketplaceRow,
} from "@/bindings";
import {
  ABOUT_FINDINGS_TITLE,
  ABOUT_NOTHING_SAID,
  LOCAL_FOLDER_LABEL,
  MARKETPLACE_PLACES_TITLE,
  SOURCE_ALIAS_LABEL,
  SOURCE_LOCATION_LABEL,
} from "@/lib/copy-marketplaces";
import {
  catalogKey,
  readErrorKey,
  subscription,
} from "@/stores/marketplaces-shared";
import { AboutSection } from "./about-section";

// Static rendering reads a zustand store's initial snapshot, so the store
// hook is wrapped to let each test seed the report this tab shows.
const stub = vi.hoisted(() => ({
  about: {} as Record<string, unknown>,
  rows: [] as unknown[],
  readErrors: {} as Record<string, string>,
}));
vi.mock("@/stores/marketplaces", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/marketplaces")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useMarketplacesStore.getState(),
      about: stub.about,
      rows: stub.rows,
      readErrors: stub.readErrors,
    };
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
    <AboutSection
      catalog={catalog}
      row={null}
      identity={null}
      meta={meta}
      counts={counts}
    />,
  );
};

const finding: CatalogFinding = {
  location: "kendex.toml",
  problem: "no skills root",
  fix: "add one",
  breakage: false,
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

  // The reading mode and the per-root table are an engineer's account of
  // kendex's own work, and the payload does not carry them; the header says
  // the tags once.
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

// A person deciding whether to unsubscribe reads three things the catalog
// does not say: which source this is on their machine, where its bytes are,
// and who uses it. They are here rather than behind a tab of their own,
// which was a tab about projects on a page about a marketplace.
describe("the About tab's source details", () => {
  const local: MarketplaceRow = {
    scope: { scope: "project", root: "/home/me/dev/kendex" },
    name: ".",
    repo: null,
    repoKey: null,
    repoIdentity: null,
    provenance: "/home/me/dev/kendex",
    path: ".",
    resolvedPath: "/home/me/dev/kendex",
    rev: null,
    commit: null,
    enabled: true,
    counts: null,
    meta: { name: "kendex" },
    mode: null,
    recordsUnreadable: false,
  };

  const withSource = (
    row: MarketplaceRow | null,
    identity: string | null,
    unreadable = false,
  ) => {
    stub.about = unreadable
      ? {}
      : { [catalogKey(catalog)]: { findings: [], updatedAt: null } };
    stub.readErrors = unreadable
      ? { [readErrorKey(catalogKey(catalog), "about")]: "fetch refused" }
      : {};
    stub.rows = row ? [row] : [];
    return renderToStaticMarkup(
      <AboutSection
        catalog={catalog}
        row={row}
        identity={identity}
        meta={row?.meta ?? null}
        counts={null}
      />,
    );
  };

  it("states where a folder source is and the alias it is declared under", () => {
    const html = withSource(local, null);
    expect(html).toContain(SOURCE_LOCATION_LABEL);
    expect(html).toContain(`${LOCAL_FOLDER_LABEL} · /home/me/dev/kendex`);
    expect(html).toContain(SOURCE_ALIAS_LABEL);
    expect(html).toContain(">.<");
  });

  // A repository nobody subscribes to has no declaration on this machine:
  // no alias, no folder, and no place that uses it.
  it("states none of it for a repository nobody subscribes to", () => {
    const html = withSource(null, null);
    expect(html).not.toContain(SOURCE_LOCATION_LABEL);
    expect(html).not.toContain(SOURCE_ALIAS_LABEL);
    expect(html).not.toContain(MARKETPLACE_PLACES_TITLE);
  });

  it("names the projects that use the source once it has an identity", () => {
    expect(withSource(local, "/home/me/dev/kendex")).toContain(
      MARKETPLACE_PLACES_TITLE,
    );
  });

  // A source whose bytes cannot be read is the one a person is deciding
  // whether to unsubscribe from. What this machine declares about it is not
  // the catalog's to withhold.
  it("keeps the source details when the catalog cannot be read", () => {
    const html = withSource(local, "/home/me/dev/kendex", true);
    expect(html).toContain("fetch refused");
    expect(html).toContain(`${LOCAL_FOLDER_LABEL} · /home/me/dev/kendex`);
    expect(html).toContain(SOURCE_ALIAS_LABEL);
    expect(html).toContain(MARKETPLACE_PLACES_TITLE);
  });
});
