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
const MINE: MineListRow = {
  state: "ready",
  row: {
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
  },
};

// The tab's own rows are not what is under test: `load` is stubbed so the
// mount reaches no command, and the tab renders its empty state while the
// poll runs behind it.
beforeEach(() => {
  vi.useFakeTimers();
  vi.clearAllMocks();
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
// over work already in review is what telling them apart prevents.
describe("a submissions read the app could not make", () => {
  const showing = async () => {
    const host = mount(<MineTab />);
    await settle();
    return host.textContent ?? "";
  };

  it("says the status is unknown where an empty list says nothing", async () => {
    useMineStore.setState({ rows: [MINE] });
    vi.mocked(commands.mineSubmissions).mockResolvedValue(
      refused("failed", FAILED),
    );

    const text = await showing();

    expect(text).toContain("Could not check your submissions");
    expect(text).toContain(FAILED);
    expect(text).toContain("Submission status unknown");
    // The offer claims nothing either: "Submit to community…" would say
    // this marketplace was never submitted, which is the unread fact.
    expect(text).toContain("Submit…");
    expect(text).not.toContain("Submit to community…");
  });

  // The control for the assertions above: the same tab, the same row, a
  // read that landed. Every string above has to go the other way, or they
  // are matching the page rather than the failure.
  it("says none of that when the read lands with nothing submitted", async () => {
    useMineStore.setState({ rows: [MINE] });
    vi.mocked(commands.mineSubmissions).mockResolvedValue(answered([]));

    const text = await showing();

    expect(text).not.toContain("Could not check your submissions");
    expect(text).not.toContain("Submission status unknown");
    expect(text).toContain("Submit to community…");
  });

  // Nothing is unknown about a folder the server could not have listed:
  // a submission is keyed by the GitHub repository, and this one has none.
  it("leaves a marketplace with no GitHub remote saying nothing", async () => {
    useMineStore.setState({
      rows: [
        {
          ...MINE,
          row: { ...MINE.row, git: { ...MINE.row.git, candidate: null } },
        },
      ],
    });
    vi.mocked(commands.mineSubmissions).mockResolvedValue(
      refused("failed", FAILED),
    );

    const text = await showing();

    expect(text).toContain("Could not check your submissions");
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
    expect(host.textContent).toContain("Submitted · in review");

    vi.mocked(commands.mineSubmissions).mockResolvedValue(
      refused("failed", FAILED),
    );
    await act(async () => {
      vi.advanceTimersByTime(POLL_MS);
    });
    await settle();

    expect(useAccountStore.getState().submissions).toEqual([ROW]);
    expect(host.textContent).toContain("Submitted · in review");
    expect(host.textContent).toContain("Could not check your submissions");
    expect(host.textContent).toContain("Re-submit…");
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
    expect(host.textContent).toContain("Submitted · in review");
  });
});
