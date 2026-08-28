import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import {
  ADA,
  account,
  answers,
  BOB,
  fresh,
  load,
  OTHER_SIGN_IN,
  ROW,
  SIGN_IN,
  serves,
  unreadable,
} from "@/test/account-store";
import {
  type AccountIdentity,
  hasCredential,
  type SettledAccount,
  useAccountStore,
} from "./account";
import { type AccountRead, setAccountReader } from "./account-read";

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
    answers({ state: "signed-in", identity: ADA, sign_in: SIGN_IN });
    await load();
    expect(account()).toEqual({
      kind: "signed-in",
      identity: ADA,
      signIn: SIGN_IN,
    });

    answers({ state: "offline", identity: ADA, sign_in: SIGN_IN });
    await load();
    expect(account()).toEqual({
      kind: "offline",
      identity: ADA,
      signIn: SIGN_IN,
    });

    answers({ state: "expired", sign_in: SIGN_IN });
    await load();
    expect(account()).toEqual({ kind: "expired", signIn: SIGN_IN });
  });

  it("keeps the expired explanation on the read that follows it", async () => {
    answers({ state: "expired", sign_in: SIGN_IN });
    await load();
    // Answering expired is what clears the credential, so the next read
    // finds none. The explanation has to outlive that read.
    answers({ state: "signed-out" });
    await load();
    expect(account()).toEqual({ kind: "expired", signIn: SIGN_IN });

    // Signing in is what takes it off the screen.
    answers({ state: "signed-in", identity: ADA, sign_in: SIGN_IN });
    await load();
    expect(account()).toEqual({
      kind: "signed-in",
      identity: ADA,
      signIn: SIGN_IN,
    });
  });

  it("carries the identity the backend names", async () => {
    serves({ kind: "signed-in", identity: ADA, signIn: SIGN_IN });
    await load();
    expect(account()).toEqual({
      kind: "signed-in",
      identity: ADA,
      signIn: SIGN_IN,
    });
  });

  it("is offline with the cached identity when the server is unreachable", async () => {
    serves({ kind: "offline", identity: ADA, signIn: SIGN_IN });
    await load();
    expect(account()).toEqual({
      kind: "offline",
      identity: ADA,
      signIn: SIGN_IN,
    });
  });

  it("is expired when the credential is no longer accepted", async () => {
    serves({ kind: "expired", signIn: SIGN_IN });
    await load();
    expect(account()).toEqual({ kind: "expired", signIn: SIGN_IN });
  });
});

// A read that failed knows nothing new, so it takes nothing away.
describe("a read that could not be made", () => {
  it("becomes offline when a name is already in hand", async () => {
    useAccountStore.setState({
      account: { kind: "signed-in", identity: ADA, signIn: SIGN_IN },
    });
    unreadable();
    await load();
    expect(account()).toEqual({
      kind: "offline",
      identity: ADA,
      signIn: SIGN_IN,
    });
    expect(useAccountStore.getState().readError).toBe("keychain locked");
  });

  it("leaves a credential with no name signed in", async () => {
    useAccountStore.setState({
      account: { kind: "signed-in", identity: null, signIn: SIGN_IN },
    });
    unreadable();
    await load();
    expect(account()).toEqual({
      kind: "signed-in",
      identity: null,
      signIn: SIGN_IN,
    });
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
    useAccountStore.setState({
      account: { kind: "signed-in", identity: ADA, signIn: SIGN_IN },
    });
    const gates = staged();
    const out = load();
    vi.mocked(commands.accountLogout).mockResolvedValue({
      status: "ok",
      data: null,
    } as Awaited<ReturnType<typeof commands.accountLogout>>);
    await useAccountStore.getState().signOut();
    gates[0]?.({ ok: { kind: "signed-in", identity: ADA, signIn: SIGN_IN } });
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
      data: { kind: "signed", sign_in: SIGN_IN },
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
    serves({ kind: "signed-in", identity: ADA, signIn: SIGN_IN });
    await signIn();
    expect(account()).toEqual({
      kind: "signed-in",
      identity: ADA,
      signIn: SIGN_IN,
    });
    expect(useAccountStore.getState().signingIn).toBe(false);
  });

  it("stays signed in when the read that follows fails", async () => {
    unreadable();
    await signIn();
    expect(hasCredential(account())).toBe(true);
    expect(account()).toEqual({
      kind: "signed-in",
      identity: null,
      signIn: SIGN_IN,
    });
  });

  // One sign-in is one change of hands. The approval stores the
  // credential and the read that follows only names it, so counting that
  // read as a second handover discards work started on the first.
  it("counts one handover for the approval and the read that names it", async () => {
    serves({ kind: "signed-in", identity: ADA, signIn: SIGN_IN });
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
      return { ok: { kind: "signed-in", identity: ADA, signIn: SIGN_IN } };
    });

    await signIn();
    await polling;

    expect(useAccountStore.getState().submissions).toEqual([ROW]);
  });
});

// The read repeats on its own now, so it must not be able to write over
// what the person just did.
// The identity says who the account belongs to. It cannot say which
// sign-in the credential came from, and those come apart in both
// directions: a person renames themselves or unlinks GitHub under one
// credential, and signs in again to get a different credential under an
// identity that has not changed at all.
describe("what a read compares to decide the credential changed hands", () => {
  const RENAMED = { name: "Ada L.", githubLogin: "ada" };
  const UNLINKED = { name: "Ada Lovelace", githubLogin: null };

  /** Reads `read` while `held` is on screen, and answers how many times
   *  the account changed hands over it. */
  const heldThenRead = async (held: SettledAccount, read: SettledAccount) => {
    useAccountStore.setState({ account: held, submissions: [ROW] });
    const before = useAccountStore.getState().handovers();
    serves(read);
    await load();
    return useAccountStore.getState().handovers() - before;
  };

  const signedIn = (identity: AccountIdentity, signIn = SIGN_IN) =>
    ({ kind: "signed-in", identity, signIn }) as const;

  // A profile rename is one account editing itself. Counting it as a
  // change of hands would clear the rows, and with a submit in flight it
  // would discard that credential's own expiry.
  it("does not count a rename under one sign-in", async () => {
    expect(await heldThenRead(signedIn(ADA), signedIn(RENAMED))).toBe(0);
    expect(useAccountStore.getState().submissions).toEqual([ROW]);
  });

  it("does not count the GitHub link being removed", async () => {
    expect(await heldThenRead(signedIn(ADA), signedIn(UNLINKED))).toBe(0);
    expect(useAccountStore.getState().submissions).toEqual([ROW]);
  });

  // The hole no comparison of identity fields could close: `kendex login`
  // in a terminal, by the person already signed in. Everything a read is
  // told about who they are is unchanged, and the credential is not the
  // one the app was holding.
  it("counts the same person signing in again", async () => {
    expect(
      await heldThenRead(signedIn(ADA), signedIn(ADA, OTHER_SIGN_IN)),
    ).toBe(1);
    expect(useAccountStore.getState().submissions).toBeNull();
  });

  it("counts a different person signing in", async () => {
    expect(
      await heldThenRead(signedIn(ADA), signedIn(BOB, OTHER_SIGN_IN)),
    ).toBe(1);
    expect(useAccountStore.getState().submissions).toBeNull();
  });

  // Core defaults `sign_in` so a credential stored before the field
  // existed still parses instead of signing that person out, and it reads
  // back empty. Empty is the absence of an answer: two such credentials
  // are unrelated, and calling them one sign-in would keep the first
  // account's rows under the second.
  it("counts a change of hands between two unnamed credentials", async () => {
    expect(await heldThenRead(signedIn(ADA, ""), signedIn(BOB, ""))).toBe(1);
    expect(useAccountStore.getState().submissions).toBeNull();
  });

  it("counts one even where nothing else about them differs", async () => {
    expect(await heldThenRead(signedIn(ADA, ""), signedIn(ADA, ""))).toBe(1);
  });

  it("counts one when a named credential replaces an unnamed one", async () => {
    expect(await heldThenRead(signedIn(ADA, ""), signedIn(ADA))).toBe(1);
  });

  it("counts nothing when the same sign-in is read again", async () => {
    expect(await heldThenRead(signedIn(ADA), signedIn(ADA))).toBe(0);
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

  const signedIn: AccountRead = {
    ok: { kind: "signed-in", identity: ADA, signIn: SIGN_IN },
  };

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
    useAccountStore.setState({
      account: { kind: "signed-in", identity: ADA, signIn: SIGN_IN },
    });
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
    useAccountStore.setState({
      account: { kind: "signed-in", identity: ADA, signIn: SIGN_IN },
    });
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
        account: { kind: "signed-in", identity: ADA, signIn: SIGN_IN },
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
      account: { kind: "signed-in", identity: ADA, signIn: SIGN_IN },
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
      account: { kind: "signed-in", identity: ADA, signIn: SIGN_IN },
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
    expect(
      await asks({ kind: "signed-in", identity: ADA, signIn: SIGN_IN }),
    ).toBe(true);
    vi.clearAllMocks();
    expect(
      await asks({ kind: "offline", identity: ADA, signIn: SIGN_IN }),
    ).toBe(true);
  });

  it("does not ask once it is signed out or expired", async () => {
    expect(await asks({ kind: "signed-out" })).toBe(false);
    expect(await asks({ kind: "expired", signIn: SIGN_IN })).toBe(false);
  });
});
