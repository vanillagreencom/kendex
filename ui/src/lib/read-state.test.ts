import { describe, expect, it } from "vitest";
import {
  invalidations,
  READ_LANDED,
  READ_PENDING,
  readFailed,
  readOf,
  readOrder,
} from "./read-state";

// The two rules every store's standing lands under, and the two pages that
// read per address. Six call sites hold one of these, and each reds on its
// own mutation — but a rule tested only through its callers can be mocked
// out from under its own guarantee, which is how a bump moved into a
// module a sibling suite stubs nearly shipped. So the contract is pinned
// here, where nothing stands between the assertion and the rule.

describe("readOrder", () => {
  // Of two answers about one thing, the later-begun read saw the newer
  // state. An older one landing after it has nothing to add, and writing
  // anyway would put the state before the newer read back on screen.
  it("refuses an older read once a newer one has begun", () => {
    const order = readOrder();
    const older = order.begin();
    const newer = order.begin();

    expect(order.lands(older)).toBe(false);
    expect(order.lands(newer)).toBe(true);
  });

  // Whichever answers first: the ordering is by when a read BEGAN, not by
  // when it came back, so the newer one landing first does not license the
  // older one behind it.
  it("refuses the older read whichever of the two answers first", () => {
    const order = readOrder();
    const older = order.begin();
    const newer = order.begin();

    expect(order.lands(newer)).toBe(true);
    expect(order.lands(older)).toBe(false);
  });

  // The only read out is the newest read out.
  it("lands a read nothing has overtaken", () => {
    const order = readOrder();
    expect(order.lands(order.begin())).toBe(true);
  });

  // What a side effect's own answer spells. It reports the state its own
  // work produced, so it is newer than anything still in flight — taking
  // the ticket at the landing is what makes that true, and it supersedes
  // every read already out.
  it("lets an answer taken at landing supersede every read out", () => {
    const order = readOrder();
    const reading = order.begin();

    expect(order.lands(order.begin())).toBe(true);
    expect(order.lands(reading)).toBe(false);
  });

  // Tickets do not expire against each other out of order: two reads out,
  // the second superseded by a third, leaves neither of the first two able
  // to write.
  it("refuses every read a later one overtook, not only the last", () => {
    const order = readOrder();
    const first = order.begin();
    const second = order.begin();
    const third = order.begin();

    expect(order.lands(first)).toBe(false);
    expect(order.lands(second)).toBe(false);
    expect(order.lands(third)).toBe(true);
  });

  // The same ticket read the other way: what tells a page its rows are
  // about to be replaced. Nothing is out before the first read, and a
  // landed read leaves nothing out.
  it("is outstanding from a read beginning until its answer lands", () => {
    const order = readOrder();
    expect(order.outstanding()).toBe(false);

    const ticket = order.begin();
    expect(order.outstanding()).toBe(true);

    order.lands(ticket);
    expect(order.outstanding()).toBe(false);
  });

  // A superseded read landing does not clear it: the newer one is still
  // out, and its answer is the one about to replace the rows.
  it("stays outstanding while a newer read is still on its way", () => {
    const order = readOrder();
    const older = order.begin();
    const newer = order.begin();

    order.lands(older);
    expect(order.outstanding()).toBe(true);

    order.lands(newer);
    expect(order.outstanding()).toBe(false);
  });

  // Each store holds its own, so one store's reads cannot rank against
  // another's.
  it("ranks reads only against the standing they are about", () => {
    const one = readOrder();
    const other = readOrder();
    const mine = one.begin();
    other.begin();
    other.begin();

    expect(one.lands(mine)).toBe(true);
  });
});

describe("invalidations", () => {
  it("keeps a read that began since the last move", () => {
    const drops = invalidations();
    const began = drops.since();

    expect(drops.stale(began)).toBe(false);
  });

  // What the read was about is gone: the cache it would fill was emptied
  // under it, and every consumer keys on presence, so letting the answer
  // land would pin the state before the change with nothing left to ask
  // again.
  it("drops a read that began before a move", () => {
    const drops = invalidations();
    const began = drops.since();
    drops.moved();

    expect(drops.stale(began)).toBe(true);
  });

  // Staleness does not wear off: a read from two changes ago is no fresher
  // than one from one change ago.
  it("keeps dropping it however many moves follow", () => {
    const drops = invalidations();
    const began = drops.since();
    drops.moved();
    drops.moved();

    expect(drops.stale(began)).toBe(true);
    expect(drops.stale(drops.since())).toBe(false);
  });

  // Unlike [readOrder], this ranks nothing: two reads under different keys
  // are not competing answers, so both survive a move that came after them.
  it("says nothing about which of two reads is newer", () => {
    const drops = invalidations();
    const one = drops.since();
    const other = drops.since();

    expect(drops.stale(one)).toBe(false);
    expect(drops.stale(other)).toBe(false);
  });
});

describe("readOf", () => {
  it("lands an answer and keeps why a refusal did not", () => {
    expect(readOf({ status: "ok" })).toEqual(READ_LANDED);
    expect(readOf({ status: "error", error: "offline" })).toEqual(
      readFailed("offline"),
    );
  });

  // The three states a surface tells apart: only a landed read may say
  // "nothing here", and a failure keeps its reason for the notice that
  // says the rows are last-known.
  it("keeps the three answers apart", () => {
    expect(READ_PENDING.status).toBe("pending");
    expect(READ_LANDED.status).toBe("landed");
    expect(readFailed("offline")).toEqual({
      status: "failed",
      error: "offline",
    });
  });
});
