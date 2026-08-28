// @vitest-environment jsdom
// The submissions poll is the only thing on this tab that keeps asking
// after the page settles, and it shows nothing of its own: a tick that
// found the sign-in dead used to be discarded, so a session could die
// under an open window and every surface go on saying signed in.
import { act } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type MineListRow } from "@/bindings";
import { useAccountStore } from "@/stores/account";
import { useMineStore } from "@/stores/mine";
import { mount, settle } from "@/test/dom";
import { MineTab } from "./mine-tab";

/** The name core mints for a sign-in; two answers about one
 *  credential carry the same one. */
const SIGN_IN = "sign-in-ada";

vi.mock("@/bindings", () => ({
  commands: {
    mineSubmissions: vi.fn(),
    mineSubmissionStates: vi.fn(),
    mineSubmitPreflight: vi.fn(),
    mineAuthoringDoc: vi.fn(),
    pickFolder: vi.fn(),
    openUrl: vi.fn(),
  },
}));

const ADA = { name: "Ada Lovelace", githubLogin: "ada" };

const ROW = {
  repo: "ada/team-skills",
  status: "pending",
  status_reason: null,
  head_commit: null,
  indexed_at: null,
};

const EXPIRED =
  "your sign-in has expired (invalid_grant) — run `kendex login` again";

const answered = <T,>(data: T) => ({ status: "ok", data }) as never;

const FAILED = "kendex.ai could not be reached";

const refused = (kind: "expired" | "failed", message: string) =>
  ({ status: "error", error: { kind, message } }) as never;

/** One authored marketplace whose GitHub remote is the repo `ROW` is
 *  about, so the row and the submission can be joined or fail to be. */
const READY = {
  path: "/home/ada/dev/team-skills",
  name: "team-skills",
  description: null,
  license: "MIT",
  counts: { skill: 1 },
  bundles: 0,
  declared: true,
  breakage: 0,
  advisory: 0,
  safetyFindings: 0,
  findings: [],
  git: {
    repository: true,
    clean: true,
    remote: "git@github.com:ada/team-skills.git",
    candidate: "ada/team-skills",
    ahead: 0,
  },
};

const MINE: MineListRow = { state: "ready", row: READY };

/** The same marketplace with no remote: nothing to key a submission by. */
const NO_REMOTE: MineListRow = {
  state: "ready",
  row: {
    ...READY,
    path: "/home/ada/dev/scratch-skills",
    git: { ...READY.git, remote: null, candidate: null },
  },
};

// The tab's own rows are not what is under test: `load` is stubbed so the
// mount reaches no command, and the tab renders its empty state while the
// poll runs behind it.
beforeEach(() => {
  vi.useFakeTimers();
  vi.clearAllMocks();
  vi.mocked(commands.mineSubmissionStates).mockResolvedValue({});
  useMineStore.setState({ rows: [], load: async () => {} });
  useAccountStore.setState({
    account: { kind: "signed-in", identity: ADA, signIn: SIGN_IN },
    error: null,
    readError: null,
    submissions: null,
    submissionsError: null,
    signingIn: false,
    userCode: null,
  });
});

afterEach(() => vi.useRealTimers());

// The interval the API names, exactly: a poll that meets the expiry is
// the whole point, and a tick that never fires proves nothing.
const POLL_MS = 60_000;

it("moves the account to expired on a poll tick that meets a dead sign-in", async () => {
  vi.mocked(commands.mineSubmissions).mockResolvedValue(answered([ROW]));
  mount(<MineTab />);
  await settle();
  expect(useAccountStore.getState().submissions).toEqual([ROW]);

  // The session dies between ticks, with nothing on this tab asking.
  vi.mocked(commands.mineSubmissions).mockResolvedValue(
    refused("expired", EXPIRED),
  );
  await act(async () => {
    vi.advanceTimersByTime(POLL_MS);
  });
  await settle();

  expect(commands.mineSubmissions).toHaveBeenCalledTimes(2);
  expect(useAccountStore.getState().account).toEqual({
    kind: "expired",
    signIn: SIGN_IN,
  });
  expect(useAccountStore.getState().submissions).toBeNull();
});

// Expiry is the credential ending, so the poll it stopped must not start
// again: the effect is keyed to holding a credential, and expired holds
// none.
it("stops polling once a tick has found the sign-in expired", async () => {
  vi.mocked(commands.mineSubmissions).mockResolvedValue(
    refused("expired", EXPIRED),
  );
  mount(<MineTab />);
  await settle();
  expect(useAccountStore.getState().account).toEqual({
    kind: "expired",
    signIn: SIGN_IN,
  });

  // The interval itself, not the store guard behind it: without the
  // cleanup, or with the effect no longer keyed to holding a credential,
  // a timer is still armed here and the advance below finds it.
  expect(vi.getTimerCount()).toBe(0);

  await act(async () => {
    vi.advanceTimersByTime(POLL_MS * 3);
  });
  await settle();
  expect(commands.mineSubmissions).toHaveBeenCalledTimes(1);
});

// A poll the server could not answer for any other reason says nothing
// about the sign-in. Signing the person out over an outage would take the
// tab away from them and lose the rows it was still showing.
it("leaves the account alone when a tick fails for any other reason", async () => {
  vi.mocked(commands.mineSubmissions).mockResolvedValue(answered([ROW]));
  mount(<MineTab />);
  await settle();

  vi.mocked(commands.mineSubmissions).mockResolvedValue(
    refused("failed", FAILED),
  );
  await act(async () => {
    vi.advanceTimersByTime(POLL_MS);
  });
  await settle();

  expect(useAccountStore.getState().account).toEqual({
    kind: "signed-in",
    identity: ADA,
    signIn: SIGN_IN,
  });
  expect(useAccountStore.getState().submissions).toEqual([ROW]);
});

// The defect this tab had: a read that never landed is not the same fact
// as a server that answered with nothing. Which of the three a
// marketplace is in is core's ruling, tested in its own crate; the halves
// asserted here are the tab's own: what it hands core, what it draws.
describe("a submissions read the app could not make", () => {
  const showing = async (states: Record<string, unknown> = {}) => {
    vi.mocked(commands.mineSubmissionStates).mockResolvedValue(states as never);
    const host = mount(<MineTab />);
    await settle();
    return host.textContent ?? "";
  };

  const asked = () => vi.mocked(commands.mineSubmissionStates).mock.lastCall;

  it("hands core the failed outcome, the rows in hand, and every marketplace", async () => {
    useMineStore.setState({ rows: [MINE, NO_REMOTE] });
    useAccountStore.setState({ submissions: [ROW] });
    vi.mocked(commands.mineSubmissions).mockResolvedValue(
      refused("failed", FAILED),
    );

    await showing();

    // The remote-less marketplace goes out with a null repo rather than
    // being left out: core answers about every marketplace this tab draws.
    expect(asked()).toEqual([
      "failed",
      [ROW],
      [
        { path: READY.path, repo: "ada/team-skills" },
        { path: "/home/ada/dev/scratch-skills", repo: null },
      ],
    ]);
  });

  // No rows and no failure is not a read that landed: it is the moment
  // before the first, and where a credential's end leaves the tab.
  it("tells core no read has been made until one does", async () => {
    useMineStore.setState({ rows: [MINE] });
    vi.mocked(commands.mineSubmissions).mockResolvedValue(answered([ROW]));

    await showing();

    const first = vi.mocked(commands.mineSubmissionStates).mock.calls[0];
    expect(first?.slice(0, 2)).toEqual(["unread", []]);
  });

  it("offers no first submit for a row core has not answered for", async () => {
    useMineStore.setState({ rows: [MINE] });
    vi.mocked(commands.mineSubmissions).mockResolvedValue(answered([ROW]));

    const text = await showing({});

    expect(text).toContain("Submit…");
    expect(text).not.toContain("Submit to community…");
    expect(text).not.toContain("Submission status unknown");
  });

  it("draws an unknown state as unknown, claiming neither offer", async () => {
    useMineStore.setState({ rows: [MINE] });
    vi.mocked(commands.mineSubmissions).mockResolvedValue(
      refused("failed", FAILED),
    );

    const text = await showing({ [READY.path]: { kind: "unknown" } });

    expect(text).toContain("Could not check your submissions");
    expect(text).toContain(FAILED);
    expect(text).toContain("Submission status unknown");
    expect(text).toContain("Submit…");
    expect(text).not.toContain("Submit to community…");
  });

  // The control: every string has to go the other way.
  it("draws a not-submitted state as nothing said at all", async () => {
    useMineStore.setState({ rows: [MINE] });
    vi.mocked(commands.mineSubmissions).mockResolvedValue(answered([]));

    const text = await showing({ [READY.path]: { kind: "not-submitted" } });

    expect(text).not.toContain("Could not check your submissions");
    expect(text).not.toContain("Submission status unknown");
    expect(text).toContain("Submit to community…");
  });

  // Stale and labelled beats empty: the rows are what the server last
  // said. The answer ruled from them is another matter, its outcome now
  // passed — a banner beside a first-submit offer is the same wrong claim.
  it("keeps the rows a tick read, and drops the answer ruled under it", async () => {
    useMineStore.setState({ rows: [MINE] });
    vi.mocked(commands.mineSubmissions).mockResolvedValue(answered([ROW]));
    vi.mocked(commands.mineSubmissionStates).mockResolvedValue({
      [READY.path]: { kind: "not-submitted" },
    } as never);
    const host = mount(<MineTab />);
    await settle();
    expect(asked()?.[0]).toBe("landed");
    expect(host.textContent).toContain("Submit to community…");

    // The replacement ask is still out when the render below happens.
    vi.mocked(commands.mineSubmissionStates).mockReturnValue(
      new Promise(() => {}) as never,
    );

    vi.mocked(commands.mineSubmissions).mockResolvedValue(
      refused("failed", FAILED),
    );
    await act(async () => {
      vi.advanceTimersByTime(POLL_MS);
    });
    await settle();

    expect(useAccountStore.getState().submissions).toEqual([ROW]);
    // The rows that tick already read reach core under the failed
    // outcome, which is all stale-but-labelled needs from this tab.
    expect(asked()).toEqual([
      "failed",
      [ROW],
      [{ path: READY.path, repo: "ada/team-skills" }],
    ]);
    expect(host.textContent).toContain("Could not check your submissions");
    expect(host.textContent).not.toContain("Submit to community…");
  });

  // Two asks overlap whenever a tick lands while one is in flight.
  it("draws the newer answer when an older ask lands after it", async () => {
    useMineStore.setState({ rows: [MINE] });
    vi.mocked(commands.mineSubmissions).mockResolvedValue(answered([]));
    const land: ((states: unknown) => void)[] = [];
    vi.mocked(commands.mineSubmissionStates).mockImplementation(
      () => new Promise((resolve) => land.push(resolve)) as never,
    );
    const host = mount(<MineTab />);
    await settle();

    // A tick that fails changes the outcome, so a second ask goes out.
    vi.mocked(commands.mineSubmissions).mockResolvedValue(
      refused("failed", FAILED),
    );
    await act(async () => {
      vi.advanceTimersByTime(POLL_MS);
    });
    await settle();
    expect(land.length).toBeGreaterThan(1);

    // The newest ask answers first, then every older one after it.
    const newest = land.length - 1;
    await act(async () => {
      land[newest]({ [READY.path]: { kind: "unknown" } });
      for (let older = 0; older < newest; older += 1) {
        land[older]({ [READY.path]: { kind: "not-submitted" } });
      }
    });
    await settle();

    expect(host.textContent).toContain("Submission status unknown");
  });

  // Nothing retries the ask, so a refusal leaves the rows unanswered.
  it("drops the answer in hand when the ask is refused", async () => {
    useMineStore.setState({ rows: [MINE] });
    vi.mocked(commands.mineSubmissions).mockResolvedValue(answered([ROW]));
    vi.mocked(commands.mineSubmissionStates).mockResolvedValue({
      [READY.path]: { kind: "submitted", row: ROW },
    } as never);
    const host = mount(<MineTab />);
    await settle();
    expect(host.textContent).toContain("Submitted · in review");
    expect(host.textContent).toContain("Re-submit…");

    // A second marketplace sends the ask out again under the same
    // outcome, so only the catch can drop the answer already in hand.
    vi.mocked(commands.mineSubmissionStates).mockRejectedValue(new Error("no"));
    await act(async () => {
      useMineStore.setState({ rows: [MINE, NO_REMOTE] });
    });
    await settle();

    expect(host.textContent).not.toContain("Submitted · in review");
    expect(host.textContent).not.toContain("Re-submit…");
    expect(host.textContent).toContain("Submit…");
  });
});
