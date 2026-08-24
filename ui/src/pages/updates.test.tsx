import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { updateRow } from "@/components/updates-test-rows";
import { UPDATES_ATTENTION_TITLE, UPDATES_EMPTY } from "@/lib/copy";
import {
  UPDATES_CHECKING,
  UPDATES_UNCONFIRMED_TITLE,
} from "@/lib/copy-updates";
import { UpdatesPage } from "./updates";

// Static markup escapes apostrophes, so a pinned copy token must be
// escaped the same way before it can be looked for.
const esc = (copy: string) => copy.replace(/'/g, "&#x27;");

// Static rendering reads a zustand store's initial snapshot, never one set
// later, so the store is wrapped to let a test stage what the last read
// left behind.
const stub = vi.hoisted(() => ({
  rows: [] as unknown[],
  loaded: true,
  error: null as string | null,
}));

vi.mock("@/stores/updates", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/updates")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useUpdatesStore.getState(),
      rows: stub.rows as UpdateRow[],
      warnings: [],
      busy: false,
      checking: false,
      loaded: stub.loaded,
      error: stub.error,
      load: async () => {},
    };
    return selector ? selector(state) : state;
  };
  return { ...mod, useUpdatesStore: Object.assign(hook, mod.useUpdatesStore) };
});

beforeEach(() => {
  stub.rows = [];
  stub.loaded = true;
  stub.error = null;
});

// Empty rows and no error read as good news, so before the first read
// answers — and after one that failed — "Everything is up to date" would
// assert the very thing kendex just said it could not verify.
describe("the Updates page across its read states", () => {
  it("says it is checking before the first read answers", () => {
    stub.loaded = false;
    const html = renderToStaticMarkup(<UpdatesPage />);
    expect(html).toContain(UPDATES_CHECKING);
    expect(html).not.toContain(UPDATES_EMPTY);
  });

  it("says the check failed and offers the retry, not up-to-dateness", () => {
    stub.loaded = false;
    stub.error = "no network";
    const html = renderToStaticMarkup(<UpdatesPage />);
    expect(html).toContain(esc(UPDATES_ATTENTION_TITLE));
    expect(html).toContain("no network");
    expect(html).toContain("Check for updates");
    expect(html).not.toContain(UPDATES_EMPTY);
  });

  it("calls a completed, error-free empty read up to date", () => {
    expect(renderToStaticMarkup(<UpdatesPage />)).toContain(UPDATES_EMPTY);
  });

  it("heads rows kept from a better read with the stale note", () => {
    stub.rows = [updateRow("gh", null)];
    stub.loaded = false;
    stub.error = "no network";
    const html = renderToStaticMarkup(<UpdatesPage />);
    expect(html).toContain(UPDATES_UNCONFIRMED_TITLE);
    expect(html).toContain("no network");
    // The kept rows are still drawn under it.
    expect(html).toContain("gh");
  });

  it("carries no stale note over rows from a current read", () => {
    stub.rows = [updateRow("gh", null)];
    expect(renderToStaticMarkup(<UpdatesPage />)).not.toContain(
      UPDATES_UNCONFIRMED_TITLE,
    );
  });
});
