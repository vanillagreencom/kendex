import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { type AccountStatus, commands } from "@/bindings";
import {
  type AccountIdentity,
  hasCredential,
  type SettledAccount,
  useAccountStore,
} from "./account";
import { type AccountRead, setAccountReader } from "./account-read";

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

const ADA = { name: "Ada Lovelace", githubLogin: "ada" };

/** What the real command answers: the state the backend settled on. */
const answers = (state: AccountStatus["state"]) =>
  vi.mocked(commands.accountStatus).mockResolvedValue({
    status: "ok",
    data: { state, endpoint: "https://kendex.ai" },
  } as Awaited<ReturnType<typeof commands.accountStatus>>);

const unreadable = (why = "keychain locked") =>
  vi.mocked(commands.accountStatus).mockResolvedValue({
    status: "error",
    error: why,
  } as Awaited<ReturnType<typeof commands.accountStatus>>);

/** What a backend that has reached the server answers with. */
const serves = (account: SettledAccount) =>
  setAccountReader(async () => ({ ok: account }));

const load = () => useAccountStore.getState().load();
const account = () => useAccountStore.getState().account;

const fresh = () =>
  useAccountStore.setState({
    account: { kind: "loading" },
    error: null,
    readError: null,
    submissions: null,
    signingIn: false,
    userCode: null,
    reading: false,
  });

beforeEach(() => {
  fresh();
  vi.clearAllMocks();
});

afterEach(() => setAccountReader(null));

describe("the account state a read settles on", () => {
  it("starts out knowing nothing", () => {
    expect(account()).toEqual({ kind: "loading" });
  });

  it("is signed out when no credential is stored", async () => {
    answers({ state: "signed-out" });
    await load();
    expect(account()).toEqual({ kind: "signed-out" });
  });

  it("carries every state the command settles on", async () => {
    answers({ state: "signed-in", identity: ADA });
    await load();
    expect(account()).toEqual({ kind: "signed-in", identity: ADA });

    answers({ state: "offline", identity: ADA });
    await load();
    expect(account()).toEqual({ kind: "offline", identity: ADA });

    answers({ state: "expired" });
    await load();
    expect(account()).toEqual({ kind: "expired" });
  });

  it("keeps the expired explanation on the read that follows it", async () => {
    answers({ state: "expired" });
    await load();
    // Answering expired is what clears the credential, so the next read
    // finds none. The explanation has to outlive that read.
    answers({ state: "signed-out" });
    await load();
    expect(account()).toEqual({ kind: "expired" });

    // Signing in is what takes it off the screen.
    answers({ state: "signed-in", identity: ADA });
    await load();
    expect(account()).toEqual({ kind: "signed-in", identity: ADA });
  });

  it("carries the identity the backend names", async () => {
    serves({ kind: "signed-in", identity: ADA });
    await load();
    expect(account()).toEqual({ kind: "signed-in", identity: ADA });
  });

  it("is offline with the cached identity when the server is unreachable", async () => {
    serves({ kind: "offline", identity: ADA });
    await load();
    expect(account()).toEqual({ kind: "offline", identity: ADA });
  });

  it("is expired when the credential is no longer accepted", async () => {
    serves({ kind: "expired" });
    await load();
    expect(account()).toEqual({ kind: "expired" });
  });
});

// A read that failed knows nothing new, so it takes nothing away.
describe("a read that could not be made", () => {
  it("becomes offline when a name is already in hand", async () => {
    useAccountStore.setState({ account: { kind: "signed-in", identity: ADA } });
    unreadable();
    await load();
    expect(account()).toEqual({ kind: "offline", identity: ADA });
    expect(useAccountStore.getState().readError).toBe("keychain locked");
  });

  it("leaves a credential with no name signed in", async () => {
    useAccountStore.setState({
      account: { kind: "signed-in", identity: null },
    });
    unreadable();
    await load();
    expect(account()).toEqual({ kind: "signed-in", identity: null });
    expect(useAccountStore.getState().readError).toBe("keychain locked");
  });

  it("claims no state at all when nothing was ever read", async () => {
    unreadable();
    await load();
    expect(account()).toEqual({ kind: "loading" });
    expect(useAccountStore.getState().readError).toBe("keychain locked");
  });

  it("settles on the next read that lands", async () => {
    unreadable();
    await load();
    answers({ state: "signed-out" });
    await load();
    expect(account()).toEqual({ kind: "signed-out" });
    expect(useAccountStore.getState().readError).toBeNull();
  });

  // typedError rethrows an Error the transport raised, so a bridge that
  // throws never reaches the Result path at all.
  it("records a bridge that threw the same as one that said no", async () => {
    vi.mocked(commands.accountStatus).mockRejectedValue(
      new Error("ipc channel closed"),
    );
    await load();
    expect(useAccountStore.getState().readError).toContain(
      "ipc channel closed",
    );
  });

  // The seam every reader passes through is what holds them to the answer
  // their type promises. A reader that throws instead would otherwise leave
  // the read with nothing recorded, nothing to retry from, and a rejection
  // nobody catches: every caller of load says `void load()`.
  it("records any reader that threw rather than answered", async () => {
    setAccountReader(async () => {
      throw new Error("the harness reader threw");
    });
    await load();
    expect(account()).toEqual({ kind: "loading" });
    expect(useAccountStore.getState().readError).toContain(
      "the harness reader threw",
    );
    expect(useAccountStore.getState().reading).toBe(false);
  });
});

// A surface offering the retry has to tell a read still on its way from one
// that was never made, and only the store knows which it is.
describe("whether a read is out", () => {
  /** A reader whose answer is released by hand. */
  const staged = () => {
    const gates: ((answer: AccountRead) => void)[] = [];
    setAccountReader(() => new Promise<AccountRead>((r) => gates.push(r)));
    return gates;
  };

  const reading = () => useAccountStore.getState().reading;

  // Read off the store's own initial state, not the one a test set up: a
  // store that opens claiming a read is out grays the retry out before
  // startup has asked for anything.
  it("is false until a read begins", () => {
    expect(useAccountStore.getInitialState().reading).toBe(false);
  });

  it("is true while the read is out and false once it lands", async () => {
    const gates = staged();
    const out = load();
    expect(reading()).toBe(true);
    gates[0]?.({ ok: { kind: "signed-out" } });
    await out;
    expect(reading()).toBe(false);
  });

  it("is false once a read that could not be made comes back", async () => {
    unreadable();
    await load();
    expect(reading()).toBe(false);
    expect(useAccountStore.getState().readError).toBe("keychain locked");
  });

  // The flag belongs to the newest read. An older one landing first must
  // not say the account is settled while the read that speaks is still out.
  it("stays true while a newer read is still out", async () => {
    const gates = staged();
    const startup = load();
    const focus = load();
    gates[0]?.({ ok: { kind: "signed-out" } });
    await startup;
    expect(reading()).toBe(true);
    gates[1]?.({ ok: { kind: "signed-out" } });
    await focus;
    expect(reading()).toBe(false);
  });

  // A read the account outran is dropped, but it was still the last read
  // out: leaving the flag up would disable a retry with nothing to wait for.
  it("is false when the read it dropped was the last one out", async () => {
    useAccountStore.setState({ account: { kind: "signed-in", identity: ADA } });
    const gates = staged();
    const out = load();
    vi.mocked(commands.accountLogout).mockResolvedValue({
      status: "ok",
      data: null,
    } as Awaited<ReturnType<typeof commands.accountLogout>>);
    await useAccountStore.getState().signOut();
    gates[0]?.({ ok: { kind: "signed-in", identity: ADA } });
    await out;
    expect(reading()).toBe(false);
    expect(account()).toEqual({ kind: "signed-out" });
  });
});

// The poll answers "signed" only after the credential is in the keychain,
// so the approval is proof and outranks anything the next read says.
describe("an approved device flow", () => {
  const approves = () => {
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
      data: "signed",
    } as Awaited<ReturnType<typeof commands.accountLoginPoll>>);
    vi.mocked(commands.openUrl).mockResolvedValue({
      status: "ok",
      data: null,
    } as Awaited<ReturnType<typeof commands.openUrl>>);
  };

  const signIn = async () => {
    vi.useFakeTimers();
    const signing = useAccountStore.getState().signIn();
    await vi.advanceTimersByTimeAsync(1100);
    await signing;
    vi.useRealTimers();
  };

  beforeEach(approves);

  it("puts the name the read brings back on the account", async () => {
    serves({ kind: "signed-in", identity: ADA });
    await signIn();
    expect(account()).toEqual({ kind: "signed-in", identity: ADA });
    expect(useAccountStore.getState().signingIn).toBe(false);
  });

  it("stays signed in when the read that follows fails", async () => {
    unreadable();
    await signIn();
    expect(hasCredential(account())).toBe(true);
    expect(account()).toEqual({ kind: "signed-in", identity: null });
  });

  // One sign-in is one change of hands. The approval stores the
  // credential and the read that follows only names it, so counting that
  // read as a second handover discards work started on the first.
  it("counts one handover for the approval and the read that names it", async () => {
    serves({ kind: "signed-in", identity: ADA });
    const before = useAccountStore.getState().handovers();
    await signIn();
    expect(useAccountStore.getState().handovers()).toBe(before + 1);
  });

  // The Mine tab asks for submissions the moment a credential exists,
  // which is before the read that names it lands. A second handover in
  // between discards the answer, and the rows read as unsubmitted until
  // the next sixty-second tick.
  it("keeps rows asked for on approval through the read that names it", async () => {
    const ROW = {
      repo: "ada/team-skills",
      status: "pending",
      status_reason: null,
      head_commit: null,
      indexed_at: null,
    };
    vi.mocked(commands.mineSubmissions).mockResolvedValue({
      status: "ok",
      data: [ROW],
    } as Awaited<ReturnType<typeof commands.mineSubmissions>>);
    let polling: Promise<void> | null = null;
    setAccountReader(async () => {
      polling = useAccountStore.getState().loadSubmissions();
      return { ok: { kind: "signed-in", identity: ADA } };
    });

    await signIn();
    await polling;

    expect(useAccountStore.getState().submissions).toEqual([ROW]);
  });
});

// The read repeats on its own now, so it must not be able to write over
// what the person just did.
// `github_login` is null for an account whose GitHub link was removed,
// not only for a credential nothing has read yet. The first is a settled
// fact about a real account and the second is a state on its way
// somewhere, and only the second is a wildcard.
describe("a read finding an account with no GitHub link", () => {
  const ADA_UNLINKED = { name: "Ada Lovelace", githubLogin: null };
  const BOB_UNLINKED = { name: "Bob", githubLogin: null };
  const ROW = {
    repo: "ada/team-skills",
    status: "pending",
    status_reason: null,
    head_commit: null,
    indexed_at: null,
  };

  const heldThenRead = async (held: AccountIdentity, read: AccountIdentity) => {
    useAccountStore.setState({
      account: { kind: "signed-in", identity: held },
      submissions: [ROW],
    });
    const before = useAccountStore.getState().handovers();
    serves({ kind: "signed-in", identity: read });
    await load();
    return useAccountStore.getState().handovers() - before;
  };

  // Two unlinked accounts are still two accounts, and the rows the first
  // one was holding are not the second one's to show.
  it("counts one unlinked account replacing another as a change of hands", async () => {
    expect(await heldThenRead(ADA_UNLINKED, BOB_UNLINKED)).toBe(1);
    expect(useAccountStore.getState().submissions).toBeNull();
    expect(account()).toEqual({ kind: "signed-in", identity: BOB_UNLINKED });
  });

  it("counts an unlinked account replacing a linked one too", async () => {
    expect(await heldThenRead(ADA, ADA_UNLINKED)).toBe(1);
    expect(useAccountStore.getState().submissions).toBeNull();
  });

  it("leaves the same unlinked account where it is", async () => {
    expect(await heldThenRead(ADA_UNLINKED, ADA_UNLINKED)).toBe(0);
    expect(useAccountStore.getState().submissions).toEqual([ROW]);
  });
});

describe("a read racing a deliberate change", () => {
  it("leaves a denied approval its explanation", async () => {
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
      status: "error",
      error: "the approval was denied",
    } as Awaited<ReturnType<typeof commands.accountLoginPoll>>);
    vi.mocked(commands.openUrl).mockResolvedValue({
      status: "ok",
      data: null,
    } as Awaited<ReturnType<typeof commands.openUrl>>);

    vi.useFakeTimers();
    const signing = useAccountStore.getState().signIn();
    await vi.advanceTimersByTimeAsync(1100);
    await signing;
    vi.useRealTimers();
    expect(useAccountStore.getState().error).toBe("the approval was denied");

    // Coming back to the window is the flow's own last step, and the read
    // it triggers must not wipe the only explanation on screen.
    answers({ state: "signed-out" });
    await load();
    expect(account()).toEqual({ kind: "signed-out" });
    expect(useAccountStore.getState().error).toBe("the approval was denied");
  });

  /** A reader whose answers are released by hand, in any order. */
  const staged = () => {
    const gates: ((answer: AccountRead) => void)[] = [];
    setAccountReader(() => new Promise<AccountRead>((r) => gates.push(r)));
    return gates;
  };

  const signedIn: AccountRead = { ok: { kind: "signed-in", identity: ADA } };

  const logsOut = () =>
    vi.mocked(commands.accountLogout).mockResolvedValue({
      status: "ok",
      data: null,
    } as Awaited<ReturnType<typeof commands.accountLogout>>);

  it("lets the newest read speak, whichever answers first", async () => {
    const gates = staged();
    const startup = load();
    const focus = load();
    gates[1]?.({ ok: { kind: "signed-out" } });
    await focus;
    gates[0]?.(signedIn);
    await startup;
    expect(account()).toEqual({ kind: "signed-out" });
  });

  it("drops a read that began before a sign-out", async () => {
    useAccountStore.setState({ account: { kind: "signed-in", identity: ADA } });
    const gates = staged();
    const reading = load();
    logsOut();
    await useAccountStore.getState().signOut();
    gates[0]?.(signedIn);
    await reading;
    expect(account()).toEqual({ kind: "signed-out" });
  });

  // The sign-out is not the account changing hands; the reply that says
  // the credential is gone is. A read begun in between knows neither.
  it("drops a read that began while a sign-out was landing", async () => {
    useAccountStore.setState({ account: { kind: "signed-in", identity: ADA } });
    const answered: { now?: () => void } = {};
    vi.mocked(commands.accountLogout).mockReturnValue(
      new Promise((resolve) => {
        answered.now = () => resolve({ status: "ok", data: null });
      }) as ReturnType<typeof commands.accountLogout>,
    );
    const out = useAccountStore.getState().signOut();
    const gates = staged();
    const reading = load();
    answered.now?.();
    await out;
    expect(account()).toEqual({ kind: "signed-out" });

    gates[0]?.(signedIn);
    await reading;
    expect(account()).toEqual({ kind: "signed-out" });
  });

  it("drops rows that arrive after the account changed hands", async () => {
    const arrivingAfter = async (change: () => Promise<void>) => {
      useAccountStore.setState({
        account: { kind: "signed-in", identity: ADA },
        submissions: [],
      });
      vi.mocked(commands.mineSubmissions).mockImplementation(async () => {
        await change();
        return { status: "ok", data: [] } as Awaited<
          ReturnType<typeof commands.mineSubmissions>
        >;
      });
      await useAccountStore.getState().loadSubmissions();
      return useAccountStore.getState().submissions;
    };
    // Hands change two ways: signing out, and a read that finds the
    // credential gone. Rows already out belong to neither account.
    logsOut();
    const out = () => useAccountStore.getState().signOut();
    expect(await arrivingAfter(out)).toBeNull();
    const observed = async () => {
      answers({ state: "signed-out" });
      await load();
    };
    expect(await arrivingAfter(observed)).toBeNull();
  });

  // Signing out drops the rows; a read that finds the credential gone has
  // to leave the same thing behind, or someone else's stay on screen.
  it("drops the submissions when a read finds the credential gone", async () => {
    useAccountStore.setState({
      account: { kind: "signed-in", identity: ADA },
      submissions: [],
    });
    answers({ state: "signed-out" });
    await load();
    expect(useAccountStore.getState().submissions).toBeNull();
  });
});

describe("signing out", () => {
  it("goes to signed out and drops the submissions with it", async () => {
    useAccountStore.setState({
      account: { kind: "signed-in", identity: ADA },
      submissions: [],
    });
    vi.mocked(commands.accountLogout).mockResolvedValue({
      status: "ok",
      data: null,
    } as Awaited<ReturnType<typeof commands.accountLogout>>);
    await useAccountStore.getState().signOut();
    expect(account()).toEqual({ kind: "signed-out" });
    expect(useAccountStore.getState().submissions).toBeNull();
  });
});

// Submissions belong to the credential, not to a confirmed session: a
// credential that could not be confirmed still owns them, and one the
// server rejected owns nothing.
describe("which states go looking for submissions", () => {
  beforeEach(() => {
    vi.mocked(commands.mineSubmissions).mockResolvedValue({
      status: "ok",
      data: [],
    } as Awaited<ReturnType<typeof commands.mineSubmissions>>);
  });

  const asks = async (state: SettledAccount) => {
    useAccountStore.setState({ account: state, submissions: null });
    await useAccountStore.getState().loadSubmissions();
    return vi.mocked(commands.mineSubmissions).mock.calls.length > 0;
  };

  it("asks while a credential is held", async () => {
    expect(await asks({ kind: "signed-in", identity: ADA })).toBe(true);
    vi.clearAllMocks();
    expect(await asks({ kind: "offline", identity: ADA })).toBe(true);
  });

  it("does not ask once it is signed out or expired", async () => {
    expect(await asks({ kind: "signed-out" })).toBe(false);
    expect(await asks({ kind: "expired" })).toBe(false);
  });
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
    useAccountStore.setState({ account: { kind: "signed-in", identity: ADA } });
    met();
    // The refusal cleared the credential, so this read finds none and
    // says signed out. What the command learned has to outlive it.
    answers({ state: "signed-out" });
    await load();
    expect(account()).toEqual({ kind: "expired" });
  });

  // KEN-742 leaves the credential, and its cached identity, where the
  // removal fails. An outage then answers `offline` for a sign-in the
  // server has already refused, and offline holds a credential: without
  // the same rule the signed-out answer gets, the dead sign-in comes
  // back usable and the Submit it cannot carry is offered again.
  it("keeps expired through a read that could not reach the server", async () => {
    useAccountStore.setState({ account: { kind: "signed-in", identity: ADA } });
    met();
    expect(account()).toEqual({ kind: "expired" });

    serves({ kind: "offline", identity: ADA });
    await load();

    expect(account()).toEqual({ kind: "expired" });
    // What the submit dialog gates its Submit button on.
    expect(hasCredential(account())).toBe(false);
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
    const BOB = { name: "Bob", githubLogin: "bob" };
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
        data: "signed",
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
      expect(account()).toEqual({ kind: "signed-in", identity: BOB });
    });

    // The route a terminal `kendex login` takes: nothing in the app signs
    // in, and the replacement arrives as a read that finds a credential
    // where there was already one.
    it("leaves a credential a terminal login put there in its place", async () => {
      serves({ kind: "signed-in", identity: BOB });
      const settled = await refusedAfter(load);

      unchangedFrom(settled);
      expect(account()).toEqual({ kind: "signed-in", identity: BOB });
      // The rows went with the account that owned them, at the read that
      // saw the change of hands, not at the refusal that landed after.
      expect(useAccountStore.getState().submissions).toBeNull();
    });
  });

  it("says nothing about the account when the refusal is anything else", () => {
    const signedIn = { kind: "signed-in" as const, identity: ADA };
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
