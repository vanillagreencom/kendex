import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import {
  ADA,
  account,
  answers,
  BOB,
  fresh,
  load,
  OTHER_SIGN_IN,
  SIGN_IN,
  serves,
} from "@/test/account-store";
import { hasCredential, useAccountStore } from "./account";

// `vi.mock` is hoisted above the imports, so its factory cannot reach one.
vi.mock("@/bindings", () => ({
  commands: {
    accountStatus: vi.fn(),
    accountLogout: vi.fn(),
    accountLoginStart: vi.fn(),
    accountLoginPoll: vi.fn(),
    mineSubmissions: vi.fn(),
    openUrl: vi.fn(),
  },
}));

beforeEach(() => {
  fresh();
  vi.clearAllMocks();
});

// A command made under the sign-in is the second way the credential is
// found to have ended; the read is the first. What the two leave behind
// has to be the same thing, or the sidebar and Settings > Account answer
// to two rules about one account.
describe("a call refused because the sign-in expired", () => {
  const expired = { kind: "expired" as const, message: "run login again" };

  /** The refusal landing under the account it was made for. */
  const met = () =>
    useAccountStore
      .getState()
      .refused(expired, useAccountStore.getState().handovers());

  it("goes to expired and drops the rows with it", () => {
    useAccountStore.setState({
      account: { kind: "signed-in", identity: ADA, signIn: SIGN_IN },
      submissions: [],
    });
    met();
    expect(account()).toEqual({ kind: "expired", signIn: SIGN_IN });
    expect(useAccountStore.getState().submissions).toBeNull();
  });

  it("keeps the explanation through the read that follows it", async () => {
    useAccountStore.setState({
      account: { kind: "signed-in", identity: ADA, signIn: SIGN_IN },
    });
    met();
    // The refusal cleared the credential, so this read finds none and
    // says signed out. What the command learned has to outlive it.
    answers({ state: "signed-out" });
    await load();
    expect(account()).toEqual({ kind: "expired", signIn: SIGN_IN });
  });

  // KEN-742 leaves the credential, and its cached identity, where the
  // removal fails. An outage then answers `offline` for a sign-in the
  // server has already refused, and offline holds a credential: without
  // the same rule the signed-out answer gets, the dead sign-in comes
  // back usable and the Submit it cannot carry is offered again.
  it("keeps expired through a read that could not reach the server", async () => {
    useAccountStore.setState({
      account: { kind: "signed-in", identity: ADA, signIn: SIGN_IN },
    });
    met();
    expect(account()).toEqual({ kind: "expired", signIn: SIGN_IN });

    serves({ kind: "offline", identity: ADA, signIn: SIGN_IN });
    await load();

    expect(account()).toEqual({ kind: "expired", signIn: SIGN_IN });
    // What the submit dialog gates its Submit button on.
    expect(hasCredential(account())).toBe(false);
  });

  // The verdict was about the sign-in it named. A credential another
  // process installed is not that one, and holding the expiry over it
  // leaves a live sign-in reading as dead with Submit withheld.
  it("lets go of it for a credential known to be a different one", async () => {
    useAccountStore.setState({
      account: { kind: "signed-in", identity: ADA, signIn: SIGN_IN },
    });
    met();

    serves({ kind: "offline", identity: BOB, signIn: OTHER_SIGN_IN });
    await load();

    expect(account()).toEqual({
      kind: "offline",
      identity: BOB,
      signIn: OTHER_SIGN_IN,
    });
    expect(hasCredential(account())).toBe(true);
  });

  // An unnamed credential is not known to be a different one, and an
  // answer that cannot see the server does not get to overturn one that
  // could on a difference nobody established.
  it("keeps it when the offline answer names no sign-in", async () => {
    useAccountStore.setState({
      account: { kind: "signed-in", identity: ADA, signIn: SIGN_IN },
    });
    met();

    serves({ kind: "offline", identity: ADA, signIn: "" });
    await load();

    expect(account()).toEqual({ kind: "expired", signIn: SIGN_IN });
  });

  it("keeps it when neither side names one", async () => {
    useAccountStore.setState({
      account: { kind: "signed-in", identity: ADA, signIn: "" },
    });
    met();

    serves({ kind: "offline", identity: ADA, signIn: "" });
    await load();

    expect(account()).toEqual({ kind: "expired", signIn: "" });
  });

  it("drops rows already out for the credential it ended", async () => {
    useAccountStore.setState({
      account: { kind: "signed-in", identity: ADA, signIn: SIGN_IN },
      submissions: null,
    });
    vi.mocked(commands.mineSubmissions).mockImplementation(async () => {
      met();
      return { status: "ok", data: [] } as Awaited<
        ReturnType<typeof commands.mineSubmissions>
      >;
    });
    await useAccountStore.getState().loadSubmissions();
    expect(useAccountStore.getState().submissions).toBeNull();
  });

  it("changes nothing once the account has already moved on", () => {
    // A sign-out taken while the call was out is the person's own
    // answer; the rejection that lands behind it is about a credential
    // they already gave up.
    useAccountStore.setState({ account: { kind: "signed-out" } });
    met();
    expect(account()).toEqual({ kind: "signed-out" });
  });

  // The expiry belongs to the credential the call went out under. A
  // submit is in flight for as long as the server takes, and the sign-in
  // can be replaced inside that window: a sign-out, a device flow
  // finishing behind the dialog, or `kendex login` in a terminal, which
  // the next window focus reads. Ending the account over an expiry that
  // is not about the credential on screen signs the person out of the
  // one they just signed into.
  describe("that lands after the sign-in it was made under is gone", () => {
    const ROW = {
      repo: "ada/team-skills",
      status: "pending",
      status_reason: null,
      head_commit: null,
      indexed_at: null,
    };

    /** Submits under the account on screen, replaces the sign-in with
     *  `replace` while it is in flight, and lands the expiry behind it.
     *  Answers what the store settled on before the refusal, which is
     *  what a refusal about a credential nobody holds must leave. */
    const refusedAfter = async (replace: () => Promise<void>) => {
      useAccountStore.setState({
        account: { kind: "signed-in", identity: ADA, signIn: SIGN_IN },
        submissions: [ROW],
      });
      const since = useAccountStore.getState().handovers();
      await replace();
      const settled = {
        account: account(),
        submissions: useAccountStore.getState().submissions,
      };
      useAccountStore.getState().refused(expired, since);
      return settled;
    };

    /** Nothing the refusal did: the account and its rows as they were. */
    const unchangedFrom = (settled: {
      account: ReturnType<typeof account>;
      submissions: ReturnType<typeof useAccountStore.getState>["submissions"];
    }) => {
      expect(account()).toEqual(settled.account);
      expect(useAccountStore.getState().submissions).toEqual(
        settled.submissions,
      );
    };

    it("leaves a sign-out where it found it", async () => {
      vi.mocked(commands.accountLogout).mockResolvedValue({
        status: "ok",
        data: null,
      } as Awaited<ReturnType<typeof commands.accountLogout>>);
      const settled = await refusedAfter(() =>
        useAccountStore.getState().signOut(),
      );
      unchangedFrom(settled);
      expect(account()).toEqual({ kind: "signed-out" });
    });

    it("leaves the credential a device flow put there in its place", async () => {
      vi.mocked(commands.accountLoginStart).mockResolvedValue({
        status: "ok",
        data: {
          deviceCode: "kxd_test",
          userCode: "ABCD-2345",
          verificationUrl: "https://kendex.ai/device",
          intervalSeconds: 1,
        },
      } as Awaited<ReturnType<typeof commands.accountLoginStart>>);
      vi.mocked(commands.accountLoginPoll).mockResolvedValue({
        status: "ok",
        data: { kind: "signed", sign_in: SIGN_IN },
      } as Awaited<ReturnType<typeof commands.accountLoginPoll>>);
      vi.mocked(commands.openUrl).mockResolvedValue({
        status: "ok",
        data: null,
      } as Awaited<ReturnType<typeof commands.openUrl>>);
      serves({ kind: "signed-in", identity: BOB, signIn: SIGN_IN });

      const settled = await refusedAfter(async () => {
        vi.useFakeTimers();
        const signing = useAccountStore.getState().signIn();
        await vi.advanceTimersByTimeAsync(1100);
        await signing;
        vi.useRealTimers();
      });

      unchangedFrom(settled);
      expect(account()).toEqual({
        kind: "signed-in",
        identity: BOB,
        signIn: SIGN_IN,
      });
    });

    // The route a terminal `kendex login` takes: nothing in the app signs
    // in, and the replacement arrives as a read that finds a credential
    // where there was already one.
    it("leaves a credential a terminal login put there in its place", async () => {
      serves({ kind: "signed-in", identity: BOB, signIn: "sign-in-next" });
      const settled = await refusedAfter(load);

      unchangedFrom(settled);
      expect(account()).toEqual({
        kind: "signed-in",
        identity: BOB,
        signIn: "sign-in-next",
      });
      // The rows went with the account that owned them, at the read that
      // saw the change of hands, not at the refusal that landed after.
      expect(useAccountStore.getState().submissions).toBeNull();
    });
  });

  it("says nothing about the account when the refusal is anything else", () => {
    const signedIn = {
      kind: "signed-in" as const,
      identity: ADA,
      signIn: SIGN_IN,
    };
    useAccountStore.setState({ account: signedIn, submissions: [] });
    useAccountStore
      .getState()
      .refused(
        { kind: "failed", message: "kendex.ai could not be reached" },
        useAccountStore.getState().handovers(),
      );
    expect(account()).toEqual(signedIn);
    expect(useAccountStore.getState().submissions).toEqual([]);
  });

  it("is what a submissions poll does with the refusal it gets", async () => {
    useAccountStore.setState({
      account: { kind: "signed-in", identity: ADA, signIn: SIGN_IN },
      submissions: [],
    });
    vi.mocked(commands.mineSubmissions).mockResolvedValue({
      status: "error",
      error: expired,
    } as Awaited<ReturnType<typeof commands.mineSubmissions>>);
    await useAccountStore.getState().loadSubmissions();
    expect(account()).toEqual({ kind: "expired", signIn: SIGN_IN });
    expect(useAccountStore.getState().submissions).toBeNull();
  });
});
