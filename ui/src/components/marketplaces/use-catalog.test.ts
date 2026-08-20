import { describe, expect, it } from "vitest";
import { readDue } from "./use-catalog";

describe("a cached read is due", () => {
  it("when a mutation has emptied the slot", () => {
    // Loaded, then dropCatalogCaches ran: present flips false, and with
    // nothing refusing the read it is asked again.
    expect(readDue(true, false, true)).toBe(false);
    expect(readDue(false, false, true)).toBe(true);
  });

  it("never while a refusal stands or the catalog is not ready", () => {
    expect(readDue(false, true, true)).toBe(false);
    expect(readDue(false, false, false)).toBe(false);
  });
});
