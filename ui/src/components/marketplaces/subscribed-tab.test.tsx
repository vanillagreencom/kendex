import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  MARKETPLACES_CHECK_FAILED_TITLE,
  MARKETPLACES_EMPTY_TITLE,
  TRY_AGAIN_LABEL,
} from "@/lib/copy";
import { SubscribedTab } from "./subscribed-tab";

// Static markup escapes apostrophes, so a pinned copy token must be
// escaped the same way before it can be looked for.
const esc = (copy: string) => copy.replace(/'/g, "&#x27;");

// Static rendering reads a zustand store's initial snapshot, never one set
// later, so the store is wrapped to let a test stage what the last read
// left behind.
const stub = vi.hoisted(() => ({
  loaded: true,
  rowsCurrent: true,
  error: null as string | null,
}));

vi.mock("@/stores/marketplaces", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/marketplaces")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useMarketplacesStore.getState(),
      rows: [],
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

beforeEach(() => {
  stub.loaded = true;
  stub.rowsCurrent = true;
  stub.error = null;
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
    stub.error = "offline";
    const html = renderToStaticMarkup(<SubscribedTab onSubscribe={() => {}} />);
    expect(html).toContain(esc(MARKETPLACES_CHECK_FAILED_TITLE));
    expect(html).toContain("offline");
    expect(html).toContain(TRY_AGAIN_LABEL);
    expect(html).not.toContain(MARKETPLACES_EMPTY_TITLE);
  });
});
