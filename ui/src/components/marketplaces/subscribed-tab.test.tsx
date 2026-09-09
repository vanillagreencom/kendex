import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { MarketplaceRow } from "@/bindings";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import {
  MARKETPLACES_CHECK_FAILED_TITLE,
  MARKETPLACES_EMPTY_TITLE,
  MARKETPLACES_UNCONFIRMED_TITLE,
  placeCountLabel,
} from "@/lib/copy-marketplaces";
import { SubscribedTab } from "./subscribed-tab";

// Static markup escapes apostrophes, so a pinned copy token must be
// escaped the same way before it can be looked for.
const esc = (copy: string) => copy.replace(/'/g, "&#x27;");

// Static rendering reads a zustand store's initial snapshot, never one set
// later, so the store is wrapped to let a test stage what the last read
// left behind.
const stub = vi.hoisted(() => ({
  rows: [] as unknown[],
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

const kept: MarketplaceRow = {
  scope: { scope: "global" },
  name: "kit",
  repo: "Acme/Kit",
  repoKey: "acme/kit",
  repoIdentity: "github.com/acme/kit",
  provenance: null,
  path: null,
  resolvedPath: null,
  rev: null,
  commit: null,
  enabled: true,
  counts: null,
  meta: null,
  mode: null,
  recordsUnreadable: false,
};

beforeEach(() => {
  stub.rows = [];
  stub.read = { status: "landed", error: null };
});

describe("SubscribedTab read outcomes", () => {
  it("keeps confirmed emptiness, pending reads and stale rows distinct", () => {
    const rows: {
      name: string;
      held: MarketplaceRow[];
      read: typeof stub.read;
      shown: string[];
      absent: string[];
    }[] = [
      {
        name: "confirmed empty",
        held: [],
        read: { status: "landed", error: null },
        shown: [MARKETPLACES_EMPTY_TITLE],
        absent: [esc(MARKETPLACES_CHECK_FAILED_TITLE)],
      },
      {
        name: "pending empty",
        held: [],
        read: { status: "pending", error: null },
        shown: [],
        absent: [
          MARKETPLACES_EMPTY_TITLE,
          esc(MARKETPLACES_CHECK_FAILED_TITLE),
        ],
      },
      {
        name: "failed empty",
        held: [],
        read: { status: "failed", error: "offline" },
        shown: [
          esc(MARKETPLACES_CHECK_FAILED_TITLE),
          "offline",
          TRY_AGAIN_LABEL,
        ],
        absent: [MARKETPLACES_EMPTY_TITLE],
      },
      {
        name: "failed with retained rows",
        held: [kept],
        read: { status: "failed", error: "offline" },
        shown: [
          MARKETPLACES_UNCONFIRMED_TITLE,
          "offline",
          TRY_AGAIN_LABEL,
          // The catalogue's own name where it has one, else the repository
          // it resolves to — `lib/marketplace-display.ts`. Never the alias
          // `kit`, which is one place's manifest key.
          "Kit",
        ],
        absent: [],
      },
      {
        name: "current with rows",
        held: [kept],
        read: { status: "landed", error: null },
        shown: [],
        absent: [MARKETPLACES_UNCONFIRMED_TITLE],
      },
    ];
    expect(rows).toHaveLength(5);
    for (const row of rows) {
      stub.rows = row.held;
      stub.read = row.read;
      const html = renderToStaticMarkup(
        <SubscribedTab onSubscribe={() => {}} />,
      );
      for (const text of row.shown) expect(html, row.name).toContain(text);
      for (const text of row.absent) expect(html, row.name).not.toContain(text);
    }
  });
});

// One card answers for the marketplace and says how many places hold it,
// rather than a row per place with nothing saying the rows are the same
// catalog.
describe("SubscribedTab with one marketplace held in several places", () => {
  it("draws one card naming every place", () => {
    stub.rows = [
      kept,
      { ...kept, scope: { scope: "project", root: "/w/alpha" } },
      { ...kept, scope: { scope: "project", root: "/w/beta" } },
    ];
    const html = renderToStaticMarkup(<SubscribedTab onSubscribe={() => {}} />);
    expect(html.match(/data-slot="card"/g)).toHaveLength(1);
    expect(html).toContain(placeCountLabel(3));
    expect(html).toContain("Personal, alpha, beta");
  });
});
