import { beforeEach, describe, expect, it, vi } from "vitest";
import { type SettledAccount, useAccountStore } from "@/stores/account";
import { mockInvoke } from "./mock";
import {
  accountFromUrl,
  installAccountReader,
  MOCK_ACCOUNTS,
  setMockAccount,
} from "./mock-account";

/** What the store settles on when it reads through the harness. */
const read = async () => {
  await useAccountStore.getState().load();
  return useAccountStore.getState().account;
};

const stored = async () =>
  ((await mockInvoke("account_status")) as { signedIn: boolean }).signedIn;

// Every state the store can settle on has to be reachable in the dev
// harness, or the pages that draw them are only ever seen in one.
describe("the account states the dev bridge can answer as", () => {
  beforeEach(() => {
    installAccountReader();
    setMockAccount(MOCK_ACCOUNTS["signed-out"]);
  });

  it("serves whichever one was picked", async () => {
    for (const [name, state] of Object.entries(MOCK_ACCOUNTS)) {
      setMockAccount(state as SettledAccount);
      expect(await read(), name).toEqual(state);
    }
  });

  it("holds a credential while signed in or offline, and not otherwise", async () => {
    setMockAccount(MOCK_ACCOUNTS["signed-in"]);
    expect(await stored()).toBe(true);
    setMockAccount(MOCK_ACCOUNTS.offline);
    expect(await stored()).toBe(true);
    setMockAccount(MOCK_ACCOUNTS.expired);
    expect(await stored()).toBe(false);
    setMockAccount(MOCK_ACCOUNTS["signed-out"]);
    expect(await stored()).toBe(false);
  });

  it("signs in through the device flow and out again", async () => {
    await mockInvoke("account_login_start");
    expect(await mockInvoke("account_login_poll")).toBe("pending");
    expect(await mockInvoke("account_login_poll")).toBe("signed");
    expect(await read()).toEqual(MOCK_ACCOUNTS["signed-in"]);
    await mockInvoke("account_logout");
    expect(await read()).toEqual(MOCK_ACCOUNTS["signed-out"]);
  });
});

describe("the state ?account= picks", () => {
  it("takes the one it names", () => {
    expect(accountFromUrl("?account=expired")).toEqual(MOCK_ACCOUNTS.expired);
    expect(accountFromUrl("?tab=mine&account=offline")).toEqual(
      MOCK_ACCOUNTS.offline,
    );
  });

  it("is signed out with no account asked for", () => {
    expect(accountFromUrl("")).toEqual(MOCK_ACCOUNTS["signed-out"]);
    expect(accountFromUrl("?tab=mine")).toEqual(MOCK_ACCOUNTS["signed-out"]);
  });

  // An object literal answers for `constructor` and `toString` too, and a
  // state that is not a state would reach the store unchallenged.
  it("says so rather than taking a name it does not have", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    for (const asked of ["constructor", "toString", "signed_in", ""]) {
      expect(accountFromUrl(`?account=${asked}`), asked).toEqual(
        MOCK_ACCOUNTS["signed-out"],
      );
    }
    expect(warn).toHaveBeenCalledTimes(4);
    warn.mockRestore();
  });
});
