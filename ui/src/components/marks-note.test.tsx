import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { MarksNote } from "./marks-note";

const stub = vi.hoisted(() => ({
  updatesError: null as string | null,
  unreadPlaces: {} as Record<string, string>,
  passError: null as string | null,
}));

vi.mock("@/stores/updates", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/updates")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useUpdatesStore.getState(),
      error: stub.updatesError,
    };
    return selector ? selector(state) : state;
  };
  return { ...mod, useUpdatesStore: Object.assign(hook, mod.useUpdatesStore) };
});

vi.mock("@/stores/editor", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/editor")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useEditorStore.getState(),
      unreadPlaces: stub.unreadPlaces,
      passError: stub.passError,
    };
    return selector ? selector(state) : state;
  };
  return { ...mod, useEditorStore: Object.assign(hook, mod.useEditorStore) };
});

beforeEach(() => {
  stub.updatesError = null;
  stub.unreadPlaces = {};
  stub.passError = null;
});

// A read that failed leaves every place unmarked, which looks exactly like
// a library nobody has customized. The difference has to be said.
describe("what the Library says when a read behind the marks fails", () => {
  it("stays silent while both reads are fine", () => {
    expect(renderToStaticMarkup(<MarksNote />)).toBe("");
  });

  it("names the update check when it is the one that failed", () => {
    stub.updatesError = "no network";
    const html = renderToStaticMarkup(<MarksNote />);
    expect(html).toContain("Your changes could not all be checked");
    expect(html).toContain("files you edited by hand are not counted");
    expect(html).toContain("no network");
    expect(html).not.toContain("settings could not be read");
  });

  it("names the places whose settings would not read", () => {
    stub.unreadPlaces = { "/work/vg": "/work/vg: expected a table" };
    const html = renderToStaticMarkup(<MarksNote />);
    expect(html).toContain("settings could not be read");
    expect(html).toContain("/work/vg: expected a table");
    expect(html).not.toContain("files you edited by hand");
  });

  // The note is about the places that are unread now, not about a read that
  // failed once: a place that reads again takes its line away, and the last
  // one to recover takes the note.
  it("stops speaking once the last place has read again", () => {
    stub.unreadPlaces = {
      "/work/vg": "/work/vg: expected a table",
      global: "global: no channel",
    };
    expect(renderToStaticMarkup(<MarksNote />)).toContain("global: no channel");

    // The targeted re-read of one place lands.
    stub.unreadPlaces = { "/work/vg": "/work/vg: expected a table" };
    const one = renderToStaticMarkup(<MarksNote />);
    expect(one).toContain("/work/vg: expected a table");
    expect(one).not.toContain("no channel");

    // And then the other.
    stub.unreadPlaces = {};
    stub.passError = null;
    expect(renderToStaticMarkup(<MarksNote />)).toBe("");
  });

  it("offers the way to try again", () => {
    stub.updatesError = "no network";
    expect(renderToStaticMarkup(<MarksNote />)).toContain("Check for updates");
  });
});
