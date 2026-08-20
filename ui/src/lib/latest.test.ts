import { describe, expect, it } from "vitest";
import { latestOnly } from "./latest";

describe("latestOnly", () => {
  it("drops an older answer that arrives after a newer request", async () => {
    const latest = latestOnly();
    let settleOld: (value: string) => void = () => {};
    const old = latest(new Promise<string>((resolve) => (settleOld = resolve)));
    const fresh = latest(Promise.resolve("pinned"));

    expect(await fresh).toBe("pinned");
    settleOld("bare HEAD");
    expect(await old).toBeUndefined();
  });

  it("passes the newest answer through", async () => {
    const latest = latestOnly();
    expect(await latest(Promise.resolve(1))).toBe(1);
  });
});
