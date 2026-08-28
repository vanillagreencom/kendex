import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import {
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

/** What the real command answers: a credential is stored, or is not. */
const stored = (signedIn: boolean) =>
  vi.mocked(commands.accountStatus).mockResolvedValue({
    status: "ok",
    data: { signedIn, endpoint: "https://kendex.ai" },
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
    stored(false);
    await load();
    expect(account()).toEqual({ kind: "signed-out" });
  });

  it("is signed in without a name until the backend has one", async () => {
    stored(true);
    await load();
    expect(account()).toEqual({ kind: "signed-in", identity: null });
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
    expect(useAccountStore.getState().error).toBe("keychain locked");
  });

  it("leaves a credential with no name signed in", async () => {
    useAccountStore.setState({
      account: { kind: "signed-in", identity: null },
    });
    unreadable();
    await load();
    expect(account()).toEqual({ kind: "signed-in", identity: null });
    expect(useAccountStore.getState().error).toBe("keychain locked");
  });

  it("claims no state at all when nothing was ever read", async () => {
    unreadable();
    await load();
    expect(account()).toEqual({ kind: "loading" });
    expect(useAccountStore.getState().error).toBe("keychain locked");
  });

  it("settles on the next read that lands", async () => {
    unreadable();
    await load();
    stored(false);
    await load();
    expect(account()).toEqual({ kind: "signed-out" });
    expect(useAccountStore.getState().error).toBeNull();
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
