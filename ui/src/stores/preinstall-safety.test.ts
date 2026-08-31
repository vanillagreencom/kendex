import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { dropCatalogCaches } from "./marketplaces-shared";
import {
  resetPreinstallSafety,
  safetyKey,
  usePreinstallSafety,
} from "./preinstall-safety";

vi.mock("@/bindings", () => ({
  commands: { marketplacePackagePreview: vi.fn() },
}));

const catalog = { by: "repo" as const, repo: "ada/skills" };
const key = safetyKey(catalog, "skill", "deploy");

const scored = (score: number) =>
  ({
    status: "ok" as const,
    data: { safety: { name: "deploy", safety: { score, deductions: [] } } },
  }) as never;

/** The drain loop runs off the microtask queue, so a landing needs a turn
 *  of the event loop to reach the store. */
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

const want = () =>
  usePreinstallSafety.getState().want(catalog, "skill", "deploy");

beforeEach(() => {
  vi.mocked(commands.marketplacePackagePreview).mockReset();
  resetPreinstallSafety();
});

// A mutation empties the scores because it may have moved the catalog every
// one of them was read from. A scan already in flight answers for the
// commit before that change, and `want` short-circuits on a stored score —
// so a stale answer allowed into the emptied slot is one nothing will ever
// ask again, for the life of the session.
describe("a score that outlives a reset", () => {
  it("is not stored, and the next mount asks again", async () => {
    let land: (value: unknown) => void = () => {};
    vi.mocked(commands.marketplacePackagePreview).mockReturnValueOnce(
      new Promise((resolve) => {
        land = resolve;
      }) as never,
    );

    want();
    await tick();
    expect(commands.marketplacePackagePreview).toHaveBeenCalledTimes(1);

    // An install lands. Driven through the drop the app declares rather
    // than the half of it this file is about, so the test covers the path
    // a mutation actually takes.
    dropCatalogCaches(() => {});

    // The scan begun before it now answers.
    land(scored(90));
    await tick();
    await tick();

    expect(usePreinstallSafety.getState().scores[key]).toBeUndefined();

    // And the row asking again is answered, rather than short-circuited on
    // a score the reset was supposed to have taken away.
    vi.mocked(commands.marketplacePackagePreview).mockResolvedValueOnce(
      scored(40),
    );
    want();
    await tick();
    await tick();

    expect(commands.marketplacePackagePreview).toHaveBeenCalledTimes(2);
    expect(usePreinstallSafety.getState().scores[key]?.safety.score).toBe(40);
  });

  // The control: with nothing invalidating it, the answer is stored and the
  // second ask is short-circuited, which is what makes the case above a
  // guard rather than a scan that never stores anything.
  it("stores an answer no reset overtook, and asks once", async () => {
    vi.mocked(commands.marketplacePackagePreview).mockResolvedValue(scored(90));

    want();
    await tick();
    await tick();
    expect(usePreinstallSafety.getState().scores[key]?.safety.score).toBe(90);

    want();
    await tick();
    expect(commands.marketplacePackagePreview).toHaveBeenCalledTimes(1);
  });
});
