import { describe, expect, it } from "vitest";
import { placesChanged } from "./places-changed";

const fresh = () => ({ current: null as string | null });

describe("noticing that the set of places changed", () => {
  it("says nothing the first time, because mount already read them", () => {
    expect(placesChanged(fresh(), ["/work/vg"])).toBe(false);
  });

  it("says so when a project is added, and once only", () => {
    const known = fresh();
    placesChanged(known, ["/work/vg"]);
    expect(placesChanged(known, ["/work/vg", "/work/api"])).toBe(true);
    expect(placesChanged(known, ["/work/vg", "/work/api"])).toBe(false);
  });

  it("says so when one is removed", () => {
    const known = fresh();
    placesChanged(known, ["/work/vg", "/work/api"]);
    expect(placesChanged(known, ["/work/vg"])).toBe(true);
  });

  it("treats no projects and an empty list alike", () => {
    const known = fresh();
    placesChanged(known, undefined);
    expect(placesChanged(known, [])).toBe(false);
  });

  it("tells apart two sets a separator would run together", () => {
    const known = fresh();
    placesChanged(known, ["/a", "/b"]);
    expect(placesChanged(known, ["/a /b"])).toBe(true);
  });
});
