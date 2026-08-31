import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { ADA, account, answers, fresh, load } from "@/test/account-store";
import { useAccountStore } from "./account";

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
  const met = () => useAccountStore.getState().refused(expired);

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

  it("changes nothing once the account has already moved on", () => {
    // A sign-out taken while the call was out is the person's own
    // answer; the rejection that lands behind it is about a credential
    // they already gave up.
    useAccountStore.setState({ account: { kind: "signed-out" } });
    met();
    expect(account()).toEqual({ kind: "signed-out" });
  });

  it("says nothing about the account when the refusal is anything else", () => {
    const signedIn = {
      kind: "signed-in" as const,
      identity: ADA,
    };
    useAccountStore.setState({ account: signedIn, submissions: [] });
    useAccountStore
      .getState()
      .refused({ kind: "failed", message: "kendex.ai could not be reached" });
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
});

// A command made under the sign-in is the second way the credential is
// found to have ended; the read is the first. What the two leave behind
// has to be the same thing, or the sidebar and Settings > Account answer
// to two rules about one account.
describe("a call refused because the sign-in expired", () => {
  const expired = { kind: "expired" as const, message: "run login again" };

  /** The refusal landing under the account it was made for. */
  const met = () => useAccountStore.getState().refused(expired);

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

  it("changes nothing once the account has already moved on", () => {
    // A sign-out taken while the call was out is the person's own
    // answer; the rejection that lands behind it is about a credential
    // they already gave up.
    useAccountStore.setState({ account: { kind: "signed-out" } });
    met();
    expect(account()).toEqual({ kind: "signed-out" });
  });

  it("says nothing about the account when the refusal is anything else", () => {
    const signedIn = {
      kind: "signed-in" as const,
      identity: ADA,
    };
    useAccountStore.setState({ account: signedIn, submissions: [] });
    useAccountStore
      .getState()
      .refused({ kind: "failed", message: "kendex.ai could not be reached" });
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
});
