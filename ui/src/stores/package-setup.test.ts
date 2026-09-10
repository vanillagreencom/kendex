import { beforeEach, describe, expect, it, vi } from "vitest";
import type { PackageSetup, Scope } from "@/bindings";
import { commands } from "@/bindings";
import { placeKey } from "@/lib/package-places";
import { declaresSetup, usePackageSetupStore } from "@/stores/package-setup";

vi.mock("@/bindings", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: { packageSetup: vi.fn() },
}));

const VG: Scope = { scope: "project", root: "/work/vg" };
const KEY = placeKey("skill", "commit-guards", VG);

const answer = (state: PackageSetup["status"]["state"]): PackageSetup => ({
  status: {
    state,
    said: [],
    canApply: true,
    canCheck: true,
    shared: true,
  },
  disclosure: null,
});

/** A read this test lands by hand, to hold one open. */
const park = () => {
  let land: (value: { status: "ok"; data: PackageSetup }) => void = () => {};
  const promise = new Promise<{ status: "ok"; data: PackageSetup }>(
    (resolve) => {
      land = resolve;
    },
  );
  return { promise, land };
};

beforeEach(() => {
  usePackageSetupStore.setState({ entries: {} });
  vi.mocked(commands.packageSetup).mockReset();
});

/** Two reads of one place can be out together: the page opening, the
 *  effects dialog closing, and a person pressing Check again over either.
 *  Whichever was issued last is the one that speaks — a slower earlier read
 *  landing afterwards would state the repository as it stood before the
 *  write that prompted the second. */
describe("two reads of one place", () => {
  it("keeps the later answer when the earlier one lands last", async () => {
    const first = park();
    const second = park();
    vi.mocked(commands.packageSetup)
      .mockReturnValueOnce(first.promise as never)
      .mockReturnValueOnce(second.promise as never);
    const store = usePackageSetupStore.getState();

    const early = store.check(VG, "commit-guards");
    const late = store.check(VG, "commit-guards");
    // The later read answers first, then the earlier one arrives.
    second.land({ status: "ok", data: answer("active") });
    await late;
    first.land({ status: "ok", data: answer("notActive") });
    await early;

    const entry = usePackageSetupStore.getState().entries[KEY];
    expect(entry?.setup?.status.state).toBe("active");
    expect(entry?.reading).toBe(false);
  });

  it("drops an answer for a package the store has moved off", async () => {
    const out = park();
    vi.mocked(commands.packageSetup).mockReturnValueOnce(out.promise as never);
    const store = usePackageSetupStore.getState();

    const reading = store.check(VG, "commit-guards");
    usePackageSetupStore.getState().forget();
    out.land({ status: "ok", data: answer("active") });
    await reading;

    expect(usePackageSetupStore.getState().entries[KEY]).toBeUndefined();
  });
});

/** Which kinds can declare a repository effect at all. A `repo-effects`
 *  block lives in a `SKILL.md` and every entry here is keyed as a skill, so
 *  a page about another kind must not ask: names are unique per kind, not
 *  across them. */
describe("the kind a setup can be declared by", () => {
  it("is the skill and nothing else", () => {
    expect(declaresSetup("skill")).toBe(true);
    for (const kind of ["agent", "command", "hook", "mcp-server"] as const) {
      expect(declaresSetup(kind)).toBe(false);
    }
  });
});
