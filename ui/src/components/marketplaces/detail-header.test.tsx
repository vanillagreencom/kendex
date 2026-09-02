import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Catalog, MarketplaceRow } from "@/bindings";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import { MARKETPLACES_UNCONFIRMED_TITLE } from "@/lib/copy-marketplaces";
import { DetailHeader } from "./detail-header";

// Static rendering reads a zustand store's initial snapshot, never one set
// later, so the store is wrapped to let a test stage what the last read
// left behind.
const stub = vi.hoisted(() => ({
  read: { status: "landed", error: null } as {
    status: "pending" | "landed" | "failed";
    error: string | null;
  },
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
  recordsUnreadable: false,
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
  stub.read = { status: "landed", error: null };
});

// The detail page selects its row from the store's retained rows, so a
// failed overview re-read leaves it drawing a subscription nobody could
// confirm — said on the page, with the retry beside it.
describe("DetailHeader for a subscription a failed read left behind", () => {
  it("says the row may be stale, with the retry", () => {
    stub.read = { status: "failed", error: "offline" };
    const html = render();
    expect(html).toContain(MARKETPLACES_UNCONFIRMED_TITLE);
    expect(html).toContain("offline");
    expect(html).toContain(TRY_AGAIN_LABEL);
  });

  it("carries no stale note over a current read", () => {
    const html = render();
    expect(html).not.toContain(MARKETPLACES_UNCONFIRMED_TITLE);
  });
});
