import { describe, expect, it } from "vitest";
import { unreadFold, whyUnread } from "./editor-order";

// The mark is per place and newest-wins, like the manifests beside it: a
// pass answers for the places it reached, and an older one cannot put back
// what a newer read of one place already settled. The reason travels with
// the mark rather than beside it, so what the note says and which places
// are unread cannot come apart.
describe("folding how each place's read went", () => {
  it("sets and clears per place", () => {
    const fold = unreadFold();
    expect(fold({}, [["a", "a: broke"]], 1)).toEqual({ a: "a: broke" });
    expect(fold({ a: "a: broke" }, [["b", "b: broke"]], 2)).toEqual({
      a: "a: broke",
      b: "b: broke",
    });
    expect(fold({ a: "a: broke", b: "b: broke" }, [["a", null]], 3)).toEqual({
      b: "b: broke",
    });
  });

  it("lets no older read answer for a place a newer one settled", () => {
    const fold = unreadFold();
    // The newer read lands first: this place is fine.
    expect(fold({ a: "a: broke" }, [["a", null]], 5)).toEqual({});
    // The older pass returns afterwards, still carrying its failure.
    expect(fold({}, [["a", "a: broke"]], 2)).toEqual({});
    // And it still answers for a place it was the newest to reach.
    expect(fold({}, [["c", "c: broke"]], 2)).toEqual({ c: "c: broke" });
  });

  it("hands back the same list when nothing moved", () => {
    const fold = unreadFold();
    const first = fold({}, [["a", "a: broke"]], 1);
    expect(fold(first, [["a", "a: broke"]], 2)).toBe(first);
  });

  // The note is the reasons of the places still unread, so a place that
  // reads again takes its line away with it — and the last one to recover
  // takes the whole note.
  it("says only what the places still unread said", () => {
    const said = (unreadPlaces: Record<string, string>, passError = null) =>
      whyUnread({ unreadPlaces, passError });
    expect(said({})).toBeNull();
    expect(said({ a: "a: broke", b: "b: broke" })).toBe("a: broke\nb: broke");
    // A pass that reached nowhere gives every place the same reason, and
    // the reader is told it once.
    expect(said({ a: "offline", b: "offline" })).toBe("offline");
  });

  // A pass that could not even find out which places there are belongs to
  // no place, so no per-place read can clear it — and with no places known
  // yet, leaving it to them would say nothing at all.
  it("still speaks for a pass that never reached a place", () => {
    expect(
      whyUnread({ unreadPlaces: {}, passError: "settings unreadable" }),
    ).toBe("settings unreadable");
    expect(
      whyUnread({ unreadPlaces: { a: "a: broke" }, passError: "offline" }),
    ).toBe("offline\na: broke");
  });
});
