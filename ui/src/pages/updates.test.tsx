import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { updateRow } from "@/components/updates-test-rows";
import {
  CHECK_FOR_UPDATES_LABEL,
  UPDATE_ALL_LABEL,
  UPDATES_ATTENTION_TITLE,
  UPDATES_EMPTY,
} from "@/lib/copy";
import {
  NEVER_CHECKED,
  UPDATE_NEEDS_CHECK_NOTE,
  UPDATES_CHECKING,
  UPDATES_UNCONFIRMED_TITLE,
} from "@/lib/copy-updates";
import { UpdatesPage } from "./updates";

// Static markup escapes apostrophes, so a pinned copy token must be
// escaped the same way before it can be looked for.
const esc = (copy: string) => copy.replace(/'/g, "&#x27;");

/** Markup for a disabled button carrying `label`. Nothing between the tag
 *  and the label may open another button: `.*` on one line of static markup
 *  would let an earlier disabled button reach this one's words and pass
 *  over a button that is live. */
const disabledButton = (label: string) =>
  new RegExp(`<button[^>]*disabled=""[^>]*>(?:(?!<button)[\\s\\S])*?${label}<`);

// Static rendering reads a zustand store's initial snapshot, never one set
// later, so the store is wrapped to let a test stage what the last read
// left behind.
const stub = vi.hoisted(() => ({
  rows: [] as unknown[],
  read: { status: "landed", error: null } as {
    status: "pending" | "landed" | "failed";
    error: string | null;
  },
  lastFetched: null as number | null,
  busy: false,
}));

vi.mock("@/stores/updates", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/updates")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useUpdatesStore.getState(),
      rows: stub.rows as UpdateRow[],
      warnings: [],
      busy: stub.busy,
      checking: false,
      read: stub.read,
      pendingFollows: [],
      lastFetched: stub.lastFetched,
      reload: async () => {},
    };
    return selector ? selector(state) : state;
  };
  return { ...mod, useUpdatesStore: Object.assign(hook, mod.useUpdatesStore) };
});

beforeEach(() => {
  stub.rows = [];
  stub.read = { status: "landed", error: null };
  stub.lastFetched = null;
  stub.busy = false;
});

/** Unix seconds `ago` seconds before now — the shape the overview reports,
 *  read against the same clock the page renders against. */
const secondsAgo = (ago: number) => Math.floor(Date.now() / 1000) - ago;

// Empty rows and no error read as good news, so before the first read
// answers — and after one that failed — "Everything is up to date" would
// assert the very thing kendex just said it could not verify.
describe("the Updates page across its read states", () => {
  it("says it is checking before the first read answers", () => {
    stub.read = { status: "pending", error: null };
    const html = renderToStaticMarkup(<UpdatesPage />);
    expect(html).toContain(UPDATES_CHECKING);
    expect(html).not.toContain(UPDATES_EMPTY);
  });

  it("says the check failed and offers the retry, not up-to-dateness", () => {
    stub.read = { status: "failed", error: "no network" };
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
    stub.read = { status: "failed", error: "no network" };
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

  // With every noteworthy row muted, a failed check used to strand the
  // page: the stale note and error with no way to try again anywhere.
  it("keeps the retry reachable when only hidden rows remain", () => {
    stub.rows = [updateRow("gh", null, { ignored: true })];
    stub.read = { status: "failed", error: "no network" };
    const html = renderToStaticMarkup(<UpdatesPage />);
    expect(html).toContain(UPDATES_UNCONFIRMED_TITLE);
    expect(html).toContain(CHECK_FOR_UPDATES_LABEL);
  });

  // The store refuses a check while a write of the standing is out, so the
  // button that starts one says so rather than taking a click the store
  // then refuses.
  it("holds Check while a write is out", () => {
    stub.rows = [updateRow("gh", null)];
    stub.busy = true;
    expect(renderToStaticMarkup(<UpdatesPage />)).toMatch(
      disabledButton(CHECK_FOR_UPDATES_LABEL),
    );
  });

  // The empty state's retry calls the same handler as the header's Check,
  // and `updateRows` clearing the last visible row renders it while that
  // write still holds `busy` — a live button the store would refuse.
  it("holds the empty state's retry while a write is out", () => {
    stub.busy = true;
    expect(renderToStaticMarkup(<UpdatesPage />)).toMatch(
      disabledButton(CHECK_FOR_UPDATES_LABEL),
    );
  });

  it("offers no header check button on a clean page with nothing visible", () => {
    stub.rows = [updateRow("gh", null, { ignored: true })];
    const html = renderToStaticMarkup(<UpdatesPage />);
    expect(html).not.toContain(CHECK_FOR_UPDATES_LABEL);
  });

  // Stale rows name a `latest` nobody confirmed; the page-wide Update all
  // waits for a check that succeeds, like the per-row actions.
  it("holds Update all over rows a failed check left behind", () => {
    stub.rows = [updateRow("one", null), updateRow("two", null)];
    stub.read = { status: "failed", error: "no network" };
    const html = renderToStaticMarkup(<UpdatesPage />);
    expect(html).toMatch(disabledButton(UPDATE_ALL_LABEL));
    expect(html).toContain(`title="${UPDATE_NEEDS_CHECK_NOTE}"`);
  });
});

// The check runs offline on load, so what is on screen can be days old
// with nothing about it saying so. Every state that presents an answer
// says how old that answer is.
describe("how fresh the page says its answer is", () => {
  it("dates the list from the last fetch behind it", () => {
    stub.rows = [updateRow("gh", null)];
    stub.lastFetched = secondsAgo(3 * 3600);
    expect(renderToStaticMarkup(<UpdatesPage />)).toContain(
      "Last checked 3h ago",
    );
  });

  // The state the hint exists for: "Everything is up to date" looks the
  // same whether it was checked a minute or a month ago.
  it("dates the up-to-date state, which is the one that hides its age", () => {
    stub.lastFetched = secondsAgo(5 * 86_400);
    const html = renderToStaticMarkup(<UpdatesPage />);
    expect(html).toContain(UPDATES_EMPTY);
    expect(html).toContain("Last checked 5d ago");
  });

  it("never dates an answer no check has produced", () => {
    stub.rows = [updateRow("gh", null)];
    const html = renderToStaticMarkup(<UpdatesPage />);
    expect(html).toContain(NEVER_CHECKED);
    expect(html).not.toMatch(/Last checked/);
  });

  // A fresh install on first launch: nothing to update and nothing fetched
  // yet. The one state where an unqualified "Everything is up to date"
  // would be pure guess, and the two hint sites cross here.
  it("does not call a scope it has never checked up to date without saying so", () => {
    const html = renderToStaticMarkup(<UpdatesPage />);
    expect(html).toContain(UPDATES_EMPTY);
    expect(html).toContain(NEVER_CHECKED);
    expect(html).not.toMatch(/Last checked/);
  });
});
