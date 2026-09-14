// @vitest-environment jsdom
import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { UPDATES_ATTENTION_TITLE } from "@/lib/copy";
import { newUpdatesLabel } from "@/lib/copy-updates";
import { mount } from "@/test/dom";
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
    unreadable: [] as unknown[],
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
    unreadable: [],
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
      unreadable: [],
      read: { status: "failed", error: "no network" },
    };
    const html = renderToStaticMarkup(<Sidebar />);
    expect(html).toContain(">?<");
    expect(html).toContain(esc(UPDATES_ATTENTION_TITLE));
  });

  // Rows kept from before the failure still carry their count — last-known
  // is worth showing — but the badge wears the Problem tone for it rather
  // than presenting the number as confirmed.
  it("keeps a last-known count, in the Problem tone", () => {
    stub.updates = {
      rows: [updateRow("gh", null)],
      unreadable: [],
      read: { status: "failed", error: "no network" },
    };
    const html = renderToStaticMarkup(<Sidebar />);
    expect(html).toContain(">1<");
    expect(html).not.toContain(">?<");
    expect(html).toContain("text-critical");
    expect(html).toContain(esc(UPDATES_ATTENTION_TITLE));
  });

  // A landed update the person has not read wears the Update tone.
  it("wears the Update tone while the update notice is unread", () => {
    stub.updates = {
      rows: [updateRow("gh", null)],
      unreadable: [],
      read: { status: "landed", error: null },
    };
    const html = renderToStaticMarkup(<Sidebar />);
    expect(html).toContain(">1<");
    expect(html).toContain("bg-info/15 text-info");
    expect(html).toContain(`>${esc(newUpdatesLabel(1))}<`);
  });

  // News that is no update to take still counts on the badge, and stays
  // unread until the person has seen it.
  it("wears the Update tone for news that is not an available update", () => {
    stub.updates = {
      rows: [
        updateRow("gone", null, {
          updateAvailable: false,
          removedUpstream: true,
          latest: null,
        }),
      ],
      unreadable: [],
      read: { status: "landed", error: null },
    };
    const html = renderToStaticMarkup(<Sidebar />);
    expect(html).toContain("bg-info/15 text-info");
    expect(html).toContain(`>${esc(newUpdatesLabel(1))}<`);
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
    const host = mount(<Sidebar />);
    const rows = [...host.querySelectorAll("nav button")];
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows) {
      expect(row.classList.contains("shrink-0"), row.textContent ?? "").toBe(
        true,
      );
    }
  });
});
