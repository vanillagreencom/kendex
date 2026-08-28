import { beforeEach, describe, expect, it } from "vitest";
import type { SettledAccount } from "@/stores/account";
import { mockInvoke } from "./mock";
import { MOCK_ACCOUNTS, setMockAccount } from "./mock-account";

const answer = async () =>
  (await mockInvoke("account_status")) as {
    signedIn: boolean;
    account: SettledAccount;
  };

// Every state the store can settle on has to be reachable in the dev
// harness, or the pages that draw them are only ever seen in one.
describe("the account states the dev bridge can answer as", () => {
  beforeEach(() => setMockAccount(MOCK_ACCOUNTS["signed-out"]));

  it("names each state `?account=` picks", () => {
    expect(Object.keys(MOCK_ACCOUNTS).sort()).toEqual([
      "expired",
      "offline",
      "signed-in",
      "signed-out",
    ]);
  });

  it("answers as whichever one was picked", async () => {
    for (const [name, state] of Object.entries(MOCK_ACCOUNTS)) {
      setMockAccount(state);
      expect((await answer()).account, name).toEqual(state);
    }
  });

  it("holds a credential while signed in or offline, and not otherwise", async () => {
    setMockAccount(MOCK_ACCOUNTS["signed-in"]);
    expect((await answer()).signedIn).toBe(true);
    setMockAccount(MOCK_ACCOUNTS.offline);
    expect((await answer()).signedIn).toBe(true);
    setMockAccount(MOCK_ACCOUNTS.expired);
    expect((await answer()).signedIn).toBe(false);
    setMockAccount(MOCK_ACCOUNTS["signed-out"]);
    expect((await answer()).signedIn).toBe(false);
  });

  it("signs in through the device flow and out again", async () => {
    await mockInvoke("account_login_start");
    expect(await mockInvoke("account_login_poll")).toBe("pending");
    expect(await mockInvoke("account_login_poll")).toBe("signed");
    expect((await answer()).account).toEqual(MOCK_ACCOUNTS["signed-in"]);
    await mockInvoke("account_logout");
    expect((await answer()).account).toEqual(MOCK_ACCOUNTS["signed-out"]);
  });
});
