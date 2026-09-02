import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { MarketplaceRow } from "@/bindings";
import {
  MARKETPLACE_PLACES_HELP,
  SOURCE_ENABLED_HELP,
  SOURCE_ENABLED_LABEL,
} from "@/lib/copy-marketplaces";
import { MarketplacePlaces } from "./marketplace-places";

// Static markup escapes apostrophes, so a pinned copy token must be
// escaped the same way before it can be looked for.
const esc = (copy: string) => copy.replace(/'/g, "&#x27;");

// Static rendering reads a zustand store's initial snapshot, never one set
// later, so the store is wrapped to let a test stage the overview's rows.
const stub = vi.hoisted(() => ({ rows: [] as unknown[] }));

vi.mock("@/stores/marketplaces", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/marketplaces")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = { ...mod.useMarketplacesStore.getState(), ...stub };
    return selector ? selector(state) : state;
  };
  return {
    ...mod,
    useMarketplacesStore: Object.assign(hook, mod.useMarketplacesStore),
  };
});

const row = (over: Partial<MarketplaceRow> = {}): MarketplaceRow => ({
  scope: { scope: "global" },
  name: "kit",
  repo: "Acme/Kit",
  repoKey: "acme/kit",
  repoIdentity: "github.com/acme/kit",
  path: null,
  rev: null,
  commit: null,
  enabled: true,
  counts: null,
  meta: null,
  mode: null,
  ...over,
});

beforeEach(() => {
  stub.rows = [];
});

describe("a marketplace's Projects section", () => {
  // The section's own help sentence names Personal too, so the order has
  // to be read off the rows rather than off the page's first mention.
  const placesListed = (html: string): string[] =>
    [...html.matchAll(/class="truncate text-sm font-medium">([^<]+)</g)].map(
      (hit) => hit[1],
    );

  it("lists every place holding it, personal first", () => {
    stub.rows = [row({ scope: { scope: "project", root: "/w/beta" } }), row()];
    const html = renderToStaticMarkup(
      <MarketplacePlaces identity="github.com/acme/kit" />,
    );
    expect(placesListed(html)).toEqual(["Personal", "beta"]);
    expect(html).toContain("/w/beta");
  });

  it("leaves out places holding a different marketplace", () => {
    stub.rows = [
      row(),
      row({
        scope: { scope: "project", root: "/w/beta" },
        name: "tools",
        repo: "Acme/Tools",
        repoKey: "acme/tools",
        repoIdentity: "github.com/acme/tools",
      }),
    ];
    const html = renderToStaticMarkup(
      <MarketplacePlaces identity="github.com/acme/kit" />,
    );
    expect(html).not.toContain("/w/beta");
  });

  // The section's switch and its Unsubscribe act on the row they are drawn
  // beside, so listing the wrong place hands a live control over another
  // marketplace's subscription — and "Remove them" uninstalls that
  // marketplace's packages. Two non-GitHub repositories sharing the alias
  // auto_alias derived for both is the way that happens.
  it("leaves out a place whose marketplace only shares this one's alias", () => {
    stub.rows = [
      row({
        repo: "https://gitlab.com/acme/kit",
        repoKey: null,
        repoIdentity: "https://gitlab.com/acme/kit",
      }),
      row({
        scope: { scope: "project", root: "/w/beta" },
        repo: "https://git.internal/tools/kit",
        repoKey: null,
        repoIdentity: "https://git.internal/tools/kit",
      }),
    ];
    const html = renderToStaticMarkup(
      <MarketplacePlaces identity="https://gitlab.com/acme/kit" />,
    );
    expect(placesListed(html)).toEqual(["Personal"]);
    expect(html).not.toContain("/w/beta");
  });

  // The switch used to sit alone on the Subscribed list with nothing but
  // "Turn off" behind it: no place named, and no answer to what turning it
  // off does to what is already installed.
  it("names what the switch does and what switching it off costs", () => {
    stub.rows = [row()];
    const html = renderToStaticMarkup(
      <MarketplacePlaces identity="github.com/acme/kit" />,
    );
    expect(html).toContain(SOURCE_ENABLED_LABEL);
    expect(html).toContain(esc(SOURCE_ENABLED_HELP));
    expect(html).toContain(esc(MARKETPLACE_PLACES_HELP));
  });

  it("draws nothing at all for a marketplace no place declares", () => {
    expect(
      renderToStaticMarkup(
        <MarketplacePlaces identity="github.com/acme/kit" />,
      ),
    ).toBe("");
  });
});
