import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AccountStatus } from "@/bindings";
import {
  hasCredential,
  type SettledAccount,
  useAccountStore,
} from "@/stores/account";
// Importing the bridge is what points the store's read at the harness.
import { mockInvoke } from "./mock";
import {
  accountFromUrl,
  isSignedIn,
  MOCK_ACCOUNT_NAMES,
  MOCK_ACCOUNTS,
  setMockAccount,
  UNREADABLE,
} from "./mock-account";

/** What the store settles on when it reads through the harness. */
const read = async () => {
  await useAccountStore.getState().load();
  return useAccountStore.getState();
};

/** The state the command reports, as its own tag names it. */
const commandState = async () =>
  ((await mockInvoke("account_status")) as AccountStatus).state.state;

// Every state the store can settle on has to be reachable in the dev
// harness, or the pages that draw them are only ever seen in one.
describe("the account states the dev bridge can answer as", () => {
  beforeEach(() => {
    setMockAccount({ ok: MOCK_ACCOUNTS["signed-out"] });
    useAccountStore.setState({ account: { kind: "loading" }, readError: null });
  });

  it("serves whichever settled state was picked", async () => {
    for (const [name, state] of Object.entries(MOCK_ACCOUNTS)) {
      setMockAccount({ ok: state as SettledAccount });
      useAccountStore.setState({ account: { kind: "loading" } });
      expect((await read()).account, name).toEqual(state);
    }
  });

  // The failure row the app draws is only worth drawing if it can be
  // looked at, so the harness answers with a read that will not land.
  it("serves a read that fails", async () => {
    setMockAccount(accountFromUrl(`?account=${UNREADABLE}`));
    const after = await read();
    expect(after.account).toEqual({ kind: "loading" });
    expect(after.readError).toBeTruthy();
    await expect(mockInvoke("account_status")).rejects.toBeTruthy();
  });

  // One answer in one place: the command and the reader are the same
  // state, so the harness cannot say two things at once.
  it("answers the command with the state the reader serves", async () => {
    for (const [name, state] of Object.entries(MOCK_ACCOUNTS)) {
      setMockAccount({ ok: state as SettledAccount });
      expect(await commandState(), name).toBe(state.kind);
      expect(isSignedIn(), name).toBe(hasCredential(state as SettledAccount));
    }
  });

  it("signs in through the device flow and out again", async () => {
    await mockInvoke("account_login_start");
    expect(await mockInvoke("account_login_poll")).toBe("pending");
    expect(await mockInvoke("account_login_poll")).toBe("signed");
    expect((await read()).account).toEqual(MOCK_ACCOUNTS["signed-in"]);
    await mockInvoke("account_logout");
    expect((await read()).account).toEqual(MOCK_ACCOUNTS["signed-out"]);
  });
});

describe("what ?account= picks", () => {
  it("takes the state it names", () => {
    expect(accountFromUrl("?account=expired")).toEqual({
      ok: MOCK_ACCOUNTS.expired,
    });
    expect(accountFromUrl("?tab=mine&account=offline")).toEqual({
      ok: MOCK_ACCOUNTS.offline,
    });
  });

  it("takes a read that fails, which is no state at all", () => {
    expect(accountFromUrl(`?account=${UNREADABLE}`)).toHaveProperty("error");
  });

  it("is signed out with no account asked for", () => {
    expect(accountFromUrl("")).toEqual({ ok: MOCK_ACCOUNTS["signed-out"] });
    expect(accountFromUrl("?tab=mine")).toEqual({
      ok: MOCK_ACCOUNTS["signed-out"],
    });
  });

  // An object literal answers for `constructor` and `toString` too, and a
  // state that is not a state would reach the store unchallenged.
  it("says so rather than taking a name it does not have", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    for (const asked of ["constructor", "toString", "signed_in", ""]) {
      expect(accountFromUrl(`?account=${asked}`), asked).toEqual({
        ok: MOCK_ACCOUNTS["signed-out"],
      });
    }
    expect(warn).toHaveBeenCalledTimes(4);
    // The hint has to name everything that really works, the failing read
    // included, or it sends the reader back to a state that does not.
    expect(warn.mock.calls[0]?.[0]).toContain(UNREADABLE);
    expect(MOCK_ACCOUNT_NAMES).toEqual([
      ...Object.keys(MOCK_ACCOUNTS),
      UNREADABLE,
    ]);
    warn.mockRestore();
  });
});
