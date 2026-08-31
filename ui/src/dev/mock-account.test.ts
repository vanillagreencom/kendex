import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { AccountCallRefused, AccountStatus } from "@/bindings";
import {
  hasCredential,
  type SettledAccount,
  useAccountStore,
} from "@/stores/account";
// Importing the bridge is what points the store's read at the harness.
import { mockInvoke } from "./mock";
import {
  accountFromUrl,
  callRefusal,
  EXPIRING_CALLS,
  expiringCallFromUrl,
  isSignedIn,
  MOCK_ACCOUNT_NAMES,
  MOCK_ACCOUNTS,
  setExpiringCall,
  setMockAccount,
  setUnreachable,
  UNREADABLE,
  unreachableFromUrl,
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
    expect(await mockInvoke("account_login_poll")).toEqual({ kind: "pending" });
    const approved = (await mockInvoke("account_login_poll")) as {
      kind: string;
      sign_in: string;
    };
    expect(approved.kind).toBe("signed");
    // The approval names the credential it stored, and the read that
    // follows has to answer with that same name or the store counts a
    // second change of hands for one sign-in.
    const settled = (await read()).account;
    expect(settled).toEqual({
      ...MOCK_ACCOUNTS["signed-in"],
    });
    await mockInvoke("account_logout");
    expect((await read()).account).toEqual(MOCK_ACCOUNTS["signed-out"]);
  });
});

// A payload of the right shape proves nothing about whether the flow it
// belongs to can be walked, and a bare string leaves every consumer
// reading `answer.error.message` with undefined. What the harness owes is
// the sequence: reach the submit, meet the expiry there, take the sign-in
// it offers, and submit again.
describe("the expiry the dev URL arms", () => {
  const REPO = "jane/team-skills";

  const answerOf = (
    command: string,
  ): Promise<{ answer?: unknown; refusal?: unknown }> =>
    mockInvoke(command, { repo: REPO }).then(
      (answer: unknown) => ({ answer }),
      (refusal: unknown) => ({ refusal }),
    );

  const refusalOf = async (command: string) =>
    (await answerOf(command)).refusal;

  beforeEach(() => {
    setMockAccount({ ok: MOCK_ACCOUNTS["signed-in"] });
    setExpiringCall(null);
  });

  afterEach(() => setExpiringCall(null));

  it("carries a person from a working submit through expiry and back", async () => {
    setExpiringCall("mine_submit");

    // The tab polls its submissions on mount. That is not the call the
    // expiry is on, so it answers and leaves the submit reachable.
    expect((await answerOf("mine_submissions")).answer).toHaveLength(1);
    expect(isSignedIn()).toBe(true);

    const refusal = await refusalOf("mine_submit");
    expect(refusal).toMatchObject({ kind: "expired" });
    expect((refusal as AccountCallRefused).message).toContain("kendex login");

    // The account does not revive underneath it: the credential went with
    // the sign-in, so the read that follows says signed out.
    expect(isSignedIn()).toBe(false);
    expect(await commandState()).toBe("signed-out");

    // The sign-in the dialog offers, and the submit that works after it.
    await mockInvoke("account_login_start");
    await mockInvoke("account_login_poll");
    expect(await mockInvoke("account_login_poll")).toMatchObject({
      kind: "signed",
    });
    expect((await answerOf("mine_submit")).answer).toMatchObject({
      status: "pending",
    });
  });

  // The poll meeting a dead sign-in is the tab's other new path, and it
  // has to be reachable without a person pressing anything.
  it("puts it on the poll instead when the poll is the call named", async () => {
    setExpiringCall("mine_submissions");
    expect(await refusalOf("mine_submissions")).toMatchObject({
      kind: "expired",
    });
    expect(isSignedIn()).toBe(false);
  });

  it("spends the expiry on one call rather than every call after it", async () => {
    setExpiringCall("mine_submit");
    expect(await refusalOf("mine_submit")).toMatchObject({ kind: "expired" });
    // Signed in again, the same call goes through: a scenario that never
    // clears cannot show a recovery.
    setMockAccount({ ok: MOCK_ACCOUNTS["signed-in"] });
    expect((await answerOf("mine_submit")).answer).toMatchObject({
      status: "pending",
    });
  });

  it("refuses about the call, not the account, with no credential to use", async () => {
    setMockAccount({ ok: MOCK_ACCOUNTS["signed-out"] });
    for (const command of EXPIRING_CALLS) {
      expect(await refusalOf(command), command).toMatchObject({
        kind: "failed",
      });
    }
  });

  it("arms only a call it has, and says so otherwise", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    expect(expiringCallFromUrl("?tab=mine&expire=mine_submit")).toBe(
      "mine_submit",
    );
    expect(expiringCallFromUrl("?tab=mine")).toBeNull();
    expect(expiringCallFromUrl("?expire=mine_forget")).toBeNull();
    expect(warn).toHaveBeenCalledTimes(1);
    warn.mockRestore();
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

// The Mine tab tells a submissions read it could not make from a server
// that answered with nothing, and no `?account=` state produces the
// first: the credential is fine, the server is not.
describe("the outage the dev URL arms", () => {
  it("reads the flag off the URL, present or absent", () => {
    expect(unreachableFromUrl("?unreachable")).toBe(true);
    expect(unreachableFromUrl("?unreachable=1")).toBe(true);
    expect(unreachableFromUrl("?account=signed-in")).toBe(false);
  });

  it("refuses every call under the sign-in, and keeps refusing", () => {
    setMockAccount({ ok: MOCK_ACCOUNTS["signed-in"] });
    setUnreachable(true);
    try {
      for (const call of EXPIRING_CALLS) {
        expect(callRefusal(call)).toEqual({
          kind: "failed",
          message: expect.stringContaining("kendex.ai could not be reached"),
        });
      }
      // The account is the one thing an outage must not touch: signing
      // the person out over it is the failure this whole state exists to
      // keep the app from confusing with an expiry.
      expect(isSignedIn()).toBe(true);
    } finally {
      setUnreachable(false);
    }
  });

  it("lets the calls through once it is off", () => {
    setMockAccount({ ok: MOCK_ACCOUNTS["signed-in"] });
    setUnreachable(false);
    expect(callRefusal("mine_submissions")).toBeNull();
  });
});
