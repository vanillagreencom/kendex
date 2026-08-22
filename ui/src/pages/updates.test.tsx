import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { updateRow } from "@/components/updates-test-rows";
import { UPDATES_UNCONFIRMED_TITLE } from "@/lib/copy-updates";
import { UpdatesPage } from "./updates";

// Static rendering reads a zustand store's initial snapshot, never one set
// later, so the store is wrapped to let a test stage what the last read
// left behind.
const stub = vi.hoisted(() => ({
  rows: [] as unknown[],
  loaded: true,
  checking: false,
  error: null as string | null,
}));

vi.mock("@/stores/updates", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/updates")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useUpdatesStore.getState(),
      rows: stub.rows,
      warnings: [],
      busy: false,
      checking: stub.checking,
      loaded: stub.loaded,
      error: stub.error,
      load: async () => {},
    };
    return selector ? selector(state) : state;
  };
  return { ...mod, useUpdatesStore: Object.assign(hook, mod.useUpdatesStore) };
});

/** Every Update button on the page, as the rendered attribute — the
 *  `disabled:` utility classes are on them either way. */
const updateButtons = (html: string) =>
  html
    .split("<button")
    .slice(1)
    .filter((one) => one.slice(0, one.indexOf("</button>")).includes(">Update"))
    .map((one) => one.slice(0, one.indexOf(">")));

beforeEach(() => {
  stub.rows = [updateRow("gh", "/work/vg"), updateRow("gh", "/work/api")];
  stub.loaded = true;
  stub.checking = false;
  stub.error = null;
});

// Keeping the last good rows so the page does not go blank is right for
// reading. Letting someone apply a revision off them once the check failed
// is the mark that called a place untouched when nobody had looked.
describe("the Updates page after a check that did not finish", () => {
  it("offers the updates while the read stands", () => {
    const buttons = updateButtons(renderToStaticMarkup(<UpdatesPage />));
    // The control: with a good read there is something to press.
    expect(buttons.length).toBeGreaterThan(0);
    expect(buttons.every((one) => !one.includes(' disabled=""'))).toBe(true);
  });

  it("takes every update away and says why, with the retry", () => {
    stub.loaded = false;
    stub.error = "no network";
    const html = renderToStaticMarkup(<UpdatesPage />);

    const buttons = updateButtons(html);
    expect(buttons.length).toBeGreaterThan(0);
    expect(buttons.every((one) => one.includes(' disabled=""'))).toBe(true);
    expect(html).toContain(UPDATES_UNCONFIRMED_TITLE);
    expect(html).toContain("nothing here can be updated until one does");
    expect(html).toContain("no network");
    expect(html).toContain("Check for updates");
  });

  // The controls on one place's own row: its Update, and the switch that
  // holds it at a revision this same read reported.
  it("takes a single place's update and its hold away too", () => {
    stub.rows = [updateRow("gh", "/work/vg")];
    stub.loaded = false;
    stub.error = "no network";
    const html = renderToStaticMarkup(<UpdatesPage />);

    const buttons = updateButtons(html);
    expect(buttons.length).toBeGreaterThan(0);
    expect(buttons.every((one) => one.includes(' disabled=""'))).toBe(true);
    // Base UI renders a switch as an aria-disabled button, not a native
    // disabled one.
    const roleSwitch = html.slice(html.indexOf('role="switch"'));
    expect(roleSwitch.slice(0, roleSwitch.indexOf(">"))).toContain(
      'aria-disabled="true"',
    );
  });

  // Nothing to show and a read that failed are not the same news: an empty
  // list means one thing after a clean check and another after a failed
  // one, and "you're up to date" can only honestly follow the first.
  it("does not call a failed read up to date", () => {
    stub.rows = [];
    stub.loaded = false;
    stub.error = "no network";
    const html = renderToStaticMarkup(<UpdatesPage />);
    expect(html).not.toContain("up to date");
    expect(html).toContain(UPDATES_UNCONFIRMED_TITLE);
  });
});

// A page that has asked nothing yet has nothing to report. "Everything is
// up to date" before the first read answers is the same claim as a place
// marked untouched when nobody had looked.
describe("the Updates page before the first read answers", () => {
  it("says it is checking rather than that nothing needs doing", () => {
    stub.rows = [];
    stub.loaded = false;
    stub.error = null;
    const html = renderToStaticMarkup(<UpdatesPage />);
    expect(html).not.toContain("Everything is up to date");
    expect(html).toContain("Checking for updates");
  });

  it("says nothing needs doing once the read comes back empty", () => {
    stub.rows = [];
    stub.loaded = true;
    stub.error = null;
    expect(renderToStaticMarkup(<UpdatesPage />)).toContain(
      "Everything is up to date",
    );
  });
});

// A check is fetching newer versions. Applying now acts on the revision
// the row had before it — and the read that follows the write retires the
// check, so the answer the person asked for is thrown away to apply the
// one it was replacing.
describe("the Updates page while a check is still fetching", () => {
  it("takes the updates away until it finishes", () => {
    stub.checking = true;
    const buttons = updateButtons(renderToStaticMarkup(<UpdatesPage />));
    expect(buttons.length).toBeGreaterThan(0);
    expect(buttons.every((one) => one.includes(' disabled=""'))).toBe(true);
  });
});
