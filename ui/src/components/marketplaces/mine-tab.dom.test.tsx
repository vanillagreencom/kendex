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

/** The same marketplace with no GitHub remote: nothing a submission could
 *  be keyed by. */
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
// as a server that answered with nothing, and offering a first submit
// over work already in review is what telling them apart prevents. Which
// of the three a marketplace is in is core's ruling, tested in
// crates/core/src/registry/submit.rs. What is asserted here is the two
// halves this tab owns: what it hands core, and what it draws back.
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

  it("hands core the landed outcome when the read comes back", async () => {
    useMineStore.setState({ rows: [MINE] });
    vi.mocked(commands.mineSubmissions).mockResolvedValue(answered([ROW]));

    await showing();

    expect(asked()).toEqual([
      "landed",
      [ROW],
      [{ path: READY.path, repo: "ada/team-skills" }],
    ]);
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

  // The control for the assertions above: the other answer core gives
  // about a marketplace nothing is listed for. Every string above has to
  // go the other way, or they are matching the page rather than the state.
  it("draws a not-submitted state as nothing said at all", async () => {
    useMineStore.setState({ rows: [MINE] });
    vi.mocked(commands.mineSubmissions).mockResolvedValue(answered([]));

    const text = await showing({ [READY.path]: { kind: "not-submitted" } });

    expect(text).not.toContain("Could not check your submissions");
    expect(text).not.toContain("Submission status unknown");
    expect(text).toContain("Submit to community…");
  });

  // Stale and labelled beats empty: the rows are what the server last
  // said, and clearing them would take away the one thing still known.
  it("keeps the rows a tick already read when a later tick fails", async () => {
    useMineStore.setState({ rows: [MINE] });
    vi.mocked(commands.mineSubmissions).mockResolvedValue(answered([ROW]));
    const host = mount(<MineTab />);
    await settle();
    expect(asked()?.[0]).toBe("landed");

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
  });

  // The ask goes out again whenever what it rules on changes, so two are
  // out at once whenever a tick lands while one is in flight. The older
  // answer describes inputs the tab has already moved past.
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

  // A read that lands takes the notice away on its own, so a server that
  // came back does not leave a warning standing over current rows.
  it("clears the notice on the next tick that lands", async () => {
    useMineStore.setState({ rows: [MINE] });
    vi.mocked(commands.mineSubmissions).mockResolvedValue(
      refused("failed", FAILED),
    );
    const host = mount(<MineTab />);
    await settle();
    expect(host.textContent).toContain("Could not check your submissions");

    vi.mocked(commands.mineSubmissions).mockResolvedValue(answered([ROW]));
    await act(async () => {
      vi.advanceTimersByTime(POLL_MS);
    });
    await settle();

    expect(host.textContent).not.toContain("Could not check your submissions");
    expect(asked()?.[0]).toBe("landed");
  });
});
