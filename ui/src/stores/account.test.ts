import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { type SettledAccount, useAccountStore } from "./account";

vi.mock("@/bindings", () => ({
  commands: {
    accountStatus: vi.fn(),
    accountLogout: vi.fn(),
    mineSubmissions: vi.fn(),
  },
}));

const ADA = { name: "Ada Lovelace", githubLogin: "ada" };

// The credential check the real command answers with; `account` is the
// part a backend that reached the server adds.
const answers = (signedIn: boolean, account?: SettledAccount) =>
  vi.mocked(commands.accountStatus).mockResolvedValue({
    status: "ok",
    data: {
      signedIn,
      endpoint: "https://kendex.ai",
      ...(account && { account }),
    },
  } as Awaited<ReturnType<typeof commands.accountStatus>>);

const load = () => useAccountStore.getState().load();

describe("the account state a read settles on", () => {
  beforeEach(() => {
    useAccountStore.setState({
      account: { kind: "loading" },
      error: null,
      submissions: null,
    });
    vi.clearAllMocks();
  });

  it("starts out knowing nothing", () => {
    expect(useAccountStore.getState().account).toEqual({ kind: "loading" });
  });

  it("is signed out when no credential is stored", async () => {
    answers(false);
    await load();
    expect(useAccountStore.getState().account).toEqual({ kind: "signed-out" });
  });

  it("is signed in without a name until the backend has one", async () => {
    answers(true);
    await load();
    expect(useAccountStore.getState().account).toEqual({
      kind: "signed-in",
      identity: null,
    });
  });

  it("carries the identity the backend names", async () => {
    answers(true, { kind: "signed-in", identity: ADA });
    await load();
    expect(useAccountStore.getState().account).toEqual({
      kind: "signed-in",
      identity: ADA,
    });
  });

  it("is offline with the cached identity when the server is unreachable", async () => {
    answers(true, { kind: "offline", identity: ADA });
    await load();
    expect(useAccountStore.getState().account).toEqual({
      kind: "offline",
      identity: ADA,
    });
  });

  it("is expired when the credential is no longer accepted", async () => {
    answers(true, { kind: "expired" });
    await load();
    expect(useAccountStore.getState().account).toEqual({ kind: "expired" });
  });

  // A failed read is not a state of its own: with a name already in hand
  // it is offline, and without one there is nothing to claim.
  it("falls back to offline on a failed read that has an identity", async () => {
    useAccountStore.setState({ account: { kind: "signed-in", identity: ADA } });
    vi.mocked(commands.accountStatus).mockResolvedValue({
      status: "error",
      error: "keychain locked",
    } as Awaited<ReturnType<typeof commands.accountStatus>>);
    await load();
    expect(useAccountStore.getState().account).toEqual({
      kind: "offline",
      identity: ADA,
    });
    expect(useAccountStore.getState().error).toBe("keychain locked");
  });

  it("reports a failed read it has no identity for and claims no state", async () => {
    vi.mocked(commands.accountStatus).mockResolvedValue({
      status: "error",
      error: "keychain locked",
    } as Awaited<ReturnType<typeof commands.accountStatus>>);
    await load();
    expect(useAccountStore.getState().account).toEqual({ kind: "loading" });
    expect(useAccountStore.getState().error).toBe("keychain locked");
  });

  it("signs out to signed out and drops the submissions with it", async () => {
    useAccountStore.setState({
      account: { kind: "signed-in", identity: ADA },
      submissions: [],
    });
    vi.mocked(commands.accountLogout).mockResolvedValue({
      status: "ok",
      data: null,
    } as Awaited<ReturnType<typeof commands.accountLogout>>);
    await useAccountStore.getState().signOut();
    expect(useAccountStore.getState().account).toEqual({ kind: "signed-out" });
    expect(useAccountStore.getState().submissions).toBeNull();
  });
});

// Submissions belong to the credential, not to a confirmed session: a
// credential that could not be confirmed still owns them, and one the
// server rejected owns nothing.
describe("which states go looking for submissions", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(commands.mineSubmissions).mockResolvedValue({
      status: "ok",
      data: [],
    } as Awaited<ReturnType<typeof commands.mineSubmissions>>);
  });

  const asks = async (account: SettledAccount) => {
    useAccountStore.setState({ account, submissions: null });
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
