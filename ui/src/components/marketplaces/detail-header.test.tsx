import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Catalog, MarketplaceRow } from "@/bindings";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import {
  MARKETPLACES_NEEDS_CHECK_NOTE,
  MARKETPLACES_UNCONFIRMED_TITLE,
} from "@/lib/copy-marketplaces";
import { DetailHeader } from "./detail-header";

// Static rendering reads a zustand store's initial snapshot, never one set
// later, so the store is wrapped to let a test stage what the last read
// left behind.
const stub = vi.hoisted(() => ({
  loaded: true,
  rowsCurrent: true,
  checkError: null as string | null,
}));

vi.mock("@/stores/marketplaces", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/marketplaces")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useMarketplacesStore.getState(),
      ...stub,
      load: async () => {},
    };
    return selector ? selector(state) : state;
  };
  return {
    ...mod,
    useMarketplacesStore: Object.assign(hook, mod.useMarketplacesStore),
  };
});

const catalog: Catalog = {
  by: "subscription",
  scope: { scope: "global" },
  source: "kit",
};

const row: MarketplaceRow = {
  scope: { scope: "global" },
  name: "kit",
  repo: "Acme/Kit",
  repoKey: "acme/kit",
  path: null,
  rev: null,
  commit: null,
  enabled: true,
  counts: null,
  meta: null,
  mode: null,
};

const render = () =>
  renderToStaticMarkup(
    <DetailHeader
      requested={catalog}
      catalog={catalog}
      row={row}
      summary={null}
    />,
  );

beforeEach(() => {
  stub.loaded = true;
  stub.rowsCurrent = true;
  stub.checkError = null;
});

// The detail page selects its row from the store's retained rows, so a
// failed overview re-read leaves it drawing a subscription nobody could
// confirm — said on the page, with its changes held until a read answers.
describe("DetailHeader for a subscription a failed read left behind", () => {
  it("holds the switch and says the row may be stale, with the retry", () => {
    stub.rowsCurrent = false;
    stub.checkError = "offline";
    const html = render();
    expect(html).toMatch(/<span[^>]*data-disabled=""[^>]*role="switch"/);
    expect(html).toContain(`title="${MARKETPLACES_NEEDS_CHECK_NOTE}"`);
    expect(html).toContain(MARKETPLACES_UNCONFIRMED_TITLE);
    expect(html).toContain("offline");
    expect(html).toContain(TRY_AGAIN_LABEL);
  });

  it("carries no stale note or held switch over a current read", () => {
    const html = render();
    expect(html).not.toContain(MARKETPLACES_UNCONFIRMED_TITLE);
    expect(html).not.toMatch(/<span[^>]*data-disabled=""[^>]*role="switch"/);
  });
});
