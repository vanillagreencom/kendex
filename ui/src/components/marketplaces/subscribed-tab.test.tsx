import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { MarketplaceRow } from "@/bindings";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import {
  MARKETPLACES_CHECK_FAILED_TITLE,
  MARKETPLACES_EMPTY_TITLE,
  MARKETPLACES_NEEDS_CHECK_NOTE,
  MARKETPLACES_UNCONFIRMED_TITLE,
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

const kept: MarketplaceRow = {
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

beforeEach(() => {
  stub.rows = [];
  stub.loaded = true;
  stub.rowsCurrent = true;
  stub.checkError = null;
});

// Empty rows after a read that failed are not a confirmed emptiness:
// "No marketplaces yet" with a Subscribe pitch would draw the failure as
// the exact good news nobody could check.
describe("SubscribedTab with nothing to list", () => {
  it("invites a subscription only after a read confirmed the emptiness", () => {
    const html = renderToStaticMarkup(<SubscribedTab onSubscribe={() => {}} />);
    expect(html).toContain(MARKETPLACES_EMPTY_TITLE);
    expect(html).not.toContain(esc(MARKETPLACES_CHECK_FAILED_TITLE));
  });

  it("shows the failure with the retry when the read failed, not the pitch", () => {
    stub.rowsCurrent = false;
    stub.checkError = "offline";
    const html = renderToStaticMarkup(<SubscribedTab onSubscribe={() => {}} />);
    expect(html).toContain(esc(MARKETPLACES_CHECK_FAILED_TITLE));
    expect(html).toContain("offline");
    expect(html).toContain(TRY_AGAIN_LABEL);
    expect(html).not.toContain(MARKETPLACES_EMPTY_TITLE);
  });
});

// Rows kept from before a failed read stay on screen, but headed as the
// last read that answered — and acting on them would act on a guess, so
// the toggle waits for a read that succeeds.
describe("SubscribedTab with rows a failed read left behind", () => {
  it("draws them under the stale note with the retry", () => {
    stub.rows = [kept];
    stub.rowsCurrent = false;
    stub.checkError = "offline";
    const html = renderToStaticMarkup(<SubscribedTab onSubscribe={() => {}} />);
    expect(html).toContain(MARKETPLACES_UNCONFIRMED_TITLE);
    expect(html).toContain("offline");
    expect(html).toContain(TRY_AGAIN_LABEL);
    // The kept rows are still drawn under it.
    expect(html).toContain("kit");
  });

  it("holds the toggle until a read succeeds again", () => {
    stub.rows = [kept];
    stub.rowsCurrent = false;
    stub.checkError = "offline";
    const html = renderToStaticMarkup(<SubscribedTab onSubscribe={() => {}} />);
    expect(html).toMatch(/<span[^>]*data-disabled=""[^>]*role="switch"/);
    expect(html).toContain(`title="${MARKETPLACES_NEEDS_CHECK_NOTE}"`);
  });

  it("carries no stale note over rows from a current read", () => {
    stub.rows = [kept];
    const html = renderToStaticMarkup(<SubscribedTab onSubscribe={() => {}} />);
    expect(html).not.toContain(MARKETPLACES_UNCONFIRMED_TITLE);
    expect(html).not.toMatch(/<span[^>]*data-disabled=""[^>]*role="switch"/);
  });
});
