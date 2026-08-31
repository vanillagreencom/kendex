import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { UPDATES_ATTENTION_TITLE } from "@/lib/copy";
import { SIDEBAR_ROW } from "@/lib/layout";
import { Sidebar } from "./sidebar";
import { updateRow } from "./updates-test-rows";

// Static markup escapes apostrophes, so a pinned copy token must be
// escaped the same way before it can be looked for.
const esc = (copy: string) => copy.replace(/'/g, "&#x27;");

// Static rendering reads a zustand store's initial snapshot, never one set
// later, so the updates store is wrapped to stage what the last check left.
const stub = vi.hoisted(() => ({
  updates: {
    rows: [] as unknown[],
    read: { status: "landed", error: null } as {
      status: "pending" | "landed" | "failed";
      error: string | null;
    },
  },
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
  stub.updates = {
    rows: [],
    read: { status: "landed", error: null },
  };
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
    stub.updates = {
      rows: [],
      read: { status: "failed", error: "no network" },
    };
    const html = renderToStaticMarkup(<Sidebar />);
    expect(html).toContain(">?<");
    expect(html).toContain(esc(UPDATES_ATTENTION_TITLE));
  });

  // Rows kept from before the failure still carry their count — last-known
  // is worth showing — but the badge wears the warning tone for it rather
  // than presenting the number as confirmed.
  it("keeps a last-known count, in the warning tone", () => {
    stub.updates = {
      rows: [updateRow("gh", null)],
      read: { status: "failed", error: "no network" },
    };
    const html = renderToStaticMarkup(<Sidebar />);
    expect(html).toContain(">1<");
    expect(html).not.toContain(">?<");
    expect(html).toContain("text-warning");
    expect(html).toContain(esc(UPDATES_ATTENTION_TITLE));
  });
});

// A 900x600 window at 200% zoom, both of which this app allows, leaves the
// sidebar shorter than its nav rows need. The nav has to give way there:
// without room to shrink it pushes the notice slot and the account row past
// the clip, where nothing can scroll to them.
describe("a sidebar column too short for its nav", () => {
  it("lets the nav shrink and scroll rather than growing the column", () => {
    const nav = renderToStaticMarkup(<Sidebar />).match(/<nav class="([^"]*)"/);
    if (!nav) throw new Error("no nav in the sidebar");
    expect(nav[1]).toContain("min-h-0");
    expect(nav[1]).toContain("overflow-y-auto");
  });

  // A squashed row is not a smaller sidebar, it is a broken one: the rows
  // keep their height and the nav scrolls past them instead.
  it("keeps every row at its own height", () => {
    expect(SIDEBAR_ROW).toContain("shrink-0");
  });
});
