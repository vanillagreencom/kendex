// @vitest-environment jsdom
// The submissions poll is the only thing on this tab that keeps asking
// after the page settles, and it shows nothing of its own: a tick that
// found the sign-in dead used to be discarded, so a session could die
// under an open window and every surface go on saying signed in.
import { act } from "react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { useAccountStore } from "@/stores/account";
import { useMineStore } from "@/stores/mine";
import { mount, settle } from "@/test/dom";
import { MineTab } from "./mine-tab";

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
  statusReason: null,
  headCommit: null,
  indexedAt: null,
};

const EXPIRED =
  "your sign-in has expired (invalid_grant) — run `kendex login` again";

const answered = <T,>(data: T) => ({ status: "ok", data }) as never;

// The tab's own rows are not what is under test: `load` is stubbed so the
// mount reaches no command, and the tab renders its empty state while the
// poll runs behind it.
beforeEach(() => {
  vi.useFakeTimers();
  vi.clearAllMocks();
  useMineStore.setState({ rows: [], load: async () => {} });
  useAccountStore.setState({
    account: { kind: "signed-in", identity: ADA },
    error: null,
    readError: null,
    submissions: null,
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
  vi.mocked(commands.mineSubmissions).mockResolvedValue({
    status: "error",
    error: { kind: "expired", message: EXPIRED },
  } as never);
  await act(async () => {
    vi.advanceTimersByTime(POLL_MS);
  });
  await settle();

  expect(commands.mineSubmissions).toHaveBeenCalledTimes(2);
  expect(useAccountStore.getState().account).toEqual({ kind: "expired" });
  expect(useAccountStore.getState().submissions).toBeNull();
});

// Expiry is the credential ending, so the poll it stopped must not start
// again: the effect is keyed to holding a credential, and expired holds
// none.
it("stops polling once a tick has found the sign-in expired", async () => {
  vi.mocked(commands.mineSubmissions).mockResolvedValue({
    status: "error",
    error: { kind: "expired", message: EXPIRED },
  } as never);
  mount(<MineTab />);
  await settle();
  expect(useAccountStore.getState().account).toEqual({ kind: "expired" });

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

  vi.mocked(commands.mineSubmissions).mockResolvedValue({
    status: "error",
    error: { kind: "failed", message: "kendex.ai could not be reached" },
  } as never);
  await act(async () => {
    vi.advanceTimersByTime(POLL_MS);
  });
  await settle();

  expect(useAccountStore.getState().account).toEqual({
    kind: "signed-in",
    identity: ADA,
  });
  expect(useAccountStore.getState().submissions).toEqual([ROW]);
});
