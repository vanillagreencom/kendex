import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { UPDATES_ATTENTION_TITLE } from "@/lib/copy";
import { Sidebar } from "./sidebar";
import { updateRow } from "./updates-test-rows";

// Static markup escapes apostrophes, so a pinned copy token must be
// escaped the same way before it can be looked for.
const esc = (copy: string) => copy.replace(/'/g, "&#x27;");

// Static rendering reads a zustand store's initial snapshot, never one set
// later, so the updates store is wrapped to stage what the last check left.
const stub = vi.hoisted(() => ({
  updates: { rows: [] as unknown[], error: null as string | null },
}));

vi.mock("@/stores/updates", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/updates")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = { ...mod.useUpdatesStore.getState(), ...stub.updates };
    return selector ? selector(state) : state;
  };
  return { ...mod, useUpdatesStore: Object.assign(hook, mod.useUpdatesStore) };
});

beforeEach(() => {
  stub.updates = { rows: [], error: null };
});

// Before the first read the badge is absent because nothing is known yet;
// after a failed check, absence would read as "nothing to update" — the
// row wears the question mark and says why instead.
describe("the Updates badge after a failed check", () => {
  it("shows no badge while nothing is known and nothing failed", () => {
    const html = renderToStaticMarkup(<Sidebar />);
    expect(html).not.toContain(esc(UPDATES_ATTENTION_TITLE));
    expect(html).not.toContain(">?<");
  });

  it("marks the row rather than staying silent", () => {
    stub.updates = { rows: [], error: "no network" };
    const html = renderToStaticMarkup(<Sidebar />);
    expect(html).toContain(">?<");
    expect(html).toContain(esc(UPDATES_ATTENTION_TITLE));
  });

  // Rows kept from before the failure still carry their count — last-known
  // is worth showing — but the badge wears the warning tone for it rather
  // than presenting the number as confirmed.
  it("keeps a last-known count, in the warning tone", () => {
    stub.updates = { rows: [updateRow("gh", null)], error: "no network" };
    const html = renderToStaticMarkup(<Sidebar />);
    expect(html).toContain(">1<");
    expect(html).not.toContain(">?<");
    expect(html).toContain("text-warning");
    expect(html).toContain(esc(UPDATES_ATTENTION_TITLE));
  });
});
