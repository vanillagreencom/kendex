import { describe, expect, it } from "vitest";
import { type Choice, isInstallable } from "./harness-select";

/** An untouched picker and an emptied one look alike in the data — both
 * carry no tools — and they mean opposite things. Untouched leaves the
 * scope's own defaults to decide; emptied is a choice to install nowhere,
 * which would report success over a plan that wrote nothing. */
describe("isInstallable", () => {
  const choice = (harnesses: Choice["harnesses"]): Choice => ({
    harnesses,
    method: null,
    optional: [],
  });

  it("lets an untouched picker through — the scope decides", () => {
    expect(isInstallable(choice(null))).toBe(true);
  });

  it("holds back a selection emptied by hand", () => {
    expect(isInstallable(choice([]))).toBe(false);
  });

  it("lets any real selection through", () => {
    expect(isInstallable(choice(["claude"]))).toBe(true);
  });
});
