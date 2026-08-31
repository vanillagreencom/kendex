import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import {
  ADA,
  account,
  answers,
  BOB,
  fresh,
  load,
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
  // A read that finds the credential replaced asks for the new account's
  // rows, so the harness has an answer for it.
  vi.mocked(commands.mineSubmissions).mockResolvedValue({
    status: "ok",
    data: [],
  } as Awaited<ReturnType<typeof commands.mineSubmissions>>);
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
      account: { kind: "signed-in", identity: ADA },
      submissions: [],
    });
    met();
    expect(account()).toEqual({ kind: "expired" });
    expect(useAccountStore.getState().submissions).toBeNull();
  });

  it("keeps the explanation through the read that follows it", async () => {
    useAccountStore.setState({
      account: { kind: "signed-in", identity: ADA },
    });
    met();
    // The refusal cleared the credential, so this read finds none and
    // says signed out. What the command learned has to outlive it.
    answers({ state: "signed-out" });
    await load();
    expect(account()).toEqual({ kind: "expired" });
  });

  it("drops rows already out for the credential it ended", async () => {
    useAccountStore.setState({
      account: { kind: "signed-in", identity: ADA },
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

  // KEN-742 leaves the credential, and its cached identity, where the
  // removal fails. An outage then answers `offline` off that warm cache
  // for a sign-in the server has already refused, and offline holds a
  // credential: without the same rule the signed-out answer gets, the dead
  // sign-in comes back usable and the Submit it cannot carry is offered
  // again.
  it("keeps expired through a read that could not reach the server", async () => {
    useAccountStore.setState({
      account: { kind: "signed-in", identity: ADA },
    });
    met();
    expect(account()).toEqual({ kind: "expired" });

    serves({ kind: "offline", identity: ADA });
    await load();

    expect(account()).toEqual({ kind: "expired" });
    // What the submit dialog gates its Submit button on.
    expect(hasCredential(account())).toBe(false);
  });

  // The control: a read that reached the server is news that outranks the
  // verdict, or an expiry could never be cleared at all.
  it("lets a signed-in read take the expiry back", async () => {
    useAccountStore.setState({
      account: { kind: "signed-in", identity: ADA },
    });
    met();

    serves({ kind: "signed-in", identity: BOB });
    await load();

    expect(account()).toEqual({ kind: "signed-in", identity: BOB });
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
        account: { kind: "signed-in", identity: ADA },
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
        data: { kind: "signed" },
      } as Awaited<ReturnType<typeof commands.accountLoginPoll>>);
      vi.mocked(commands.openUrl).mockResolvedValue({
        status: "ok",
        data: null,
      } as Awaited<ReturnType<typeof commands.openUrl>>);
      serves({ kind: "signed-in", identity: BOB });

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
      });
    });
  });

  it("says nothing about the account when the refusal is anything else", () => {
    const signedIn = {
      kind: "signed-in" as const,
      identity: ADA,
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
      account: { kind: "signed-in", identity: ADA },
      submissions: [],
    });
    vi.mocked(commands.mineSubmissions).mockResolvedValue({
      status: "error",
      error: expired,
    } as Awaited<ReturnType<typeof commands.mineSubmissions>>);
    await useAccountStore.getState().loadSubmissions();
    expect(account()).toEqual({ kind: "expired" });
    expect(useAccountStore.getState().submissions).toBeNull();
  });
});

// The other refusal. It says nothing about the credential, so the account
// stays where it is — but it does say the rows on screen are no longer
// confirmed, and dropping that left the tab reporting work already in
// review as never submitted.
describe("a submissions read the server could not answer", () => {
  const ROW = {
    repo: "ada/team-skills",
    status: "pending",
    status_reason: null,
    head_commit: null,
    indexed_at: null,
  };
  const WHY = "kendex.ai could not be reached";

  const signedIn = {
    kind: "signed-in" as const,
    identity: ADA,
  };

  const fails = () =>
    vi.mocked(commands.mineSubmissions).mockResolvedValue({
      status: "error",
      error: { kind: "failed", message: WHY },
    } as Awaited<ReturnType<typeof commands.mineSubmissions>>);

  it("records why, and leaves the rows it could not refresh", async () => {
    useAccountStore.setState({ account: signedIn, submissions: [ROW] });
    fails();

    await useAccountStore.getState().loadSubmissions();

    expect(useAccountStore.getState().submissionsError).toBe(WHY);
    expect(useAccountStore.getState().submissions).toEqual([ROW]);
    expect(account()).toEqual(signedIn);
  });

  // Expiry is the credential ending, and the rows go with it. A failure
  // about a read of them would sit on the Mine tab over an account the
  // sidebar and Settings already say is expired.
  it("leaves nothing behind when the same read meets a dead sign-in", async () => {
    useAccountStore.setState({
      account: signedIn,
      submissions: [ROW],
      submissionsError: WHY,
    });
    vi.mocked(commands.mineSubmissions).mockResolvedValue({
      status: "error",
      error: { kind: "expired", message: "run login again" },
    } as Awaited<ReturnType<typeof commands.mineSubmissions>>);

    await useAccountStore.getState().loadSubmissions();

    expect(account()).toEqual({ kind: "expired" });
    expect(useAccountStore.getState().submissions).toBeNull();
    expect(useAccountStore.getState().submissionsError).toBeNull();
  });

  // A rejected call is a read that failed, not an exception for the poll's
  // `void` caller to drop on the floor. It says nothing about the
  // credential, so the account stays where it is and the rows say why they
  // are not current.
  it("lands a rejected poll as a failed read, not a thrown one", async () => {
    useAccountStore.setState({ account: signedIn, submissions: [ROW] });
    vi.mocked(commands.mineSubmissions).mockRejectedValue(
      new Error("the bridge is gone"),
    );

    await expect(
      useAccountStore.getState().loadSubmissions(),
    ).resolves.toBeUndefined();

    expect(useAccountStore.getState().submissionsError).toBe(
      "the bridge is gone",
    );
    expect(useAccountStore.getState().submissions).toEqual([ROW]);
    expect(account()).toEqual(signedIn);
  });

  it("goes with the credential when the person signs out", async () => {
    useAccountStore.setState({ account: signedIn, submissionsError: WHY });
    vi.mocked(commands.accountLogout).mockResolvedValue({
      status: "ok",
      data: null,
    } as Awaited<ReturnType<typeof commands.accountLogout>>);

    await useAccountStore.getState().signOut();

    expect(useAccountStore.getState().submissionsError).toBeNull();
  });

  it("takes the failure back when a later read lands", async () => {
    useAccountStore.setState({ account: signedIn, submissionsError: WHY });

    await useAccountStore.getState().loadSubmissions();

    expect(useAccountStore.getState().submissionsError).toBeNull();
    expect(useAccountStore.getState().submissions).toEqual([]);
  });
  // The tab's timer and a submit that just landed both ask, so two reads
  // are routinely out at once. Whichever was asked for last is the later
  // word on the same credential, and it is the one that has to stand
  // however the responses come back.
  describe("two reads out at once", () => {
    type Answer = Awaited<ReturnType<typeof commands.mineSubmissions>>;

    /** Hands back the two reads' resolvers in the order they were asked
     *  for, both still out. */
    const bothOut = () => {
      const land: ((answer: Answer) => void)[] = [];
      vi.mocked(commands.mineSubmissions).mockImplementation(
        () => new Promise<Answer>((resolve) => land.push(resolve)),
      );
      useAccountStore.setState({ account: signedIn });
      const first = useAccountStore.getState().loadSubmissions();
      const second = useAccountStore.getState().loadSubmissions();
      return { land, first, second };
    };

    const landed = { status: "ok", data: [ROW] } as Answer;
    const failed = {
      status: "error",
      error: { kind: "failed", message: WHY },
    } as Answer;

    it("keeps the newer success when the older read fails last", async () => {
      const { land, first, second } = bothOut();
      land[1](landed);
      await second;
      land[0](failed);
      await first;

      expect(useAccountStore.getState().submissions).toEqual([ROW]);
      expect(useAccountStore.getState().submissionsError).toBeNull();
    });

    it("keeps the newer failure when the older read lands last", async () => {
      const { land, first, second } = bothOut();
      land[1](failed);
      await second;
      land[0](landed);
      await first;

      expect(useAccountStore.getState().submissionsError).toBe(WHY);
      expect(useAccountStore.getState().submissions).toBeNull();
    });
  });

  // The guards and the write have to be one continuation. Handing the
  // answer back across an await puts a microtask between them, and a
  // sign-out resolving its own await lands in that gap: the guards let
  // the rows through, the account ends, and the rows are written over it.
  // Reachable only by interleaving, never by a click.
  it("writes no rows over an account that ended after the guards", async () => {
    useAccountStore.setState({ account: signedIn });
    type Answer = Awaited<ReturnType<typeof commands.mineSubmissions>>;
    type Out = Awaited<ReturnType<typeof commands.accountLogout>>;
    let landRows: (answer: Answer) => void = () => {};
    let landOut: (answer: Out) => void = () => {};
    vi.mocked(commands.mineSubmissions).mockReturnValue(
      new Promise<Answer>((resolve) => {
        landRows = resolve;
      }),
    );
    vi.mocked(commands.accountLogout).mockReturnValue(
      new Promise<Out>((resolve) => {
        landOut = resolve;
      }),
    );

    const polling = useAccountStore.getState().loadSubmissions();
    const out = useAccountStore.getState().signOut();
    // The read answers first, so its guards run while the account is
    // still held; the sign-out lands in the microtask straight after.
    landRows({ status: "ok", data: [ROW] });
    landOut({ status: "ok", data: null });
    await Promise.all([polling, out]);

    expect(account()).toEqual({ kind: "signed-out" });
    expect(useAccountStore.getState().submissions).toBeNull();
  });
});
