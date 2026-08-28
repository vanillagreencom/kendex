import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { type AccountStatus, commands } from "@/bindings";
import {
  type AccountRead,
  hasCredential,
  type SettledAccount,
  setAccountReader,
  useAccountStore,
} from "./account";

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
});

// The read repeats on its own now, so it must not be able to write over
// what the person just did.
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
