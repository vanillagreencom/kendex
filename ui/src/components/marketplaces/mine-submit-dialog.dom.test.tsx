// @vitest-environment jsdom
// Signed in from the terminal, first launch with kendex.ai unreachable:
// the read fails with no identity to fall back on, so the account is
// still unknown and the dialog offers a sign-in. The reason it is
// offering one has to be on screen with it.
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type MineRow, type SubmitPreflight } from "@/bindings";
import { useAccountStore } from "@/stores/account";
import { mount, settle } from "@/test/dom";
import { MineSubmitDialog } from "./mine-submit-dialog";

vi.mock("@/bindings", () => ({
  commands: {
    mineSubmit: vi.fn(),
    mineSubmitPreflight: vi.fn(),
    openUrl: vi.fn(),
  },
}));

const row: MineRow = {
  path: "/home/jane/dev/team-skills",
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
    remote: "git@github.com:jane/team-skills.git",
    candidate: "jane/team-skills",
    ahead: 0,
  },
};

const preflight: SubmitPreflight = {
  row,
  checks: [
    { ok: true, label: "A git repository with a GitHub remote", fix: null },
  ],
  candidate: "jane/team-skills",
  ready: true,
};

const UNREACHABLE = "kendex.ai could not be reached";
const EXPIRED =
  "your sign-in has expired (invalid_grant) — run `kendex login` again";

const button = (label: string) =>
  Array.from(document.body.querySelectorAll("button")).find(
    (candidate) => candidate.textContent === label,
  );

const JANE = { name: "Jane", githubLogin: "jane" };

/** Signed in, with the folder ready to go: what the dialog looks like the
 *  moment before the submit that meets the refusal under test. */
const readyToSubmit = () => {
  vi.clearAllMocks();
  vi.mocked(commands.mineSubmitPreflight).mockResolvedValue({
    status: "ok",
    data: preflight,
  } as never);
  useAccountStore.setState({
    account: { kind: "signed-in", identity: JANE },
    error: null,
    readError: null,
    submissions: [],
    signingIn: false,
    userCode: null,
  });
};

const showDialog = () =>
  mount(
    <MineSubmitDialog
      path={row.path}
      open={true}
      onOpenChange={() => {}}
      onSubmitted={() => {}}
    />,
  );

describe("the submit dialog when the account could not be read", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.mocked(commands.mineSubmitPreflight).mockResolvedValue({
      status: "ok",
      data: preflight,
    } as never);
    useAccountStore.setState({
      account: { kind: "loading" },
      error: null,
      readError: null,
      submissions: null,
      signingIn: false,
      userCode: null,
    });
  });

  it("names the failure that left the account unknown", async () => {
    useAccountStore.setState({ readError: UNREACHABLE });
    mount(
      <MineSubmitDialog
        path={row.path}
        open={true}
        onOpenChange={() => {}}
        onSubmitted={() => {}}
      />,
    );
    await settle();

    const alert = document.body.querySelector('[role="alert"]');
    expect(alert?.textContent).toBe(UNREACHABLE);
  });

  it("keeps the device flow's own failure ahead of it", async () => {
    // A denied approval is the person's explanation for what just
    // happened; a read that failed behind it must not take its place.
    useAccountStore.setState({
      readError: UNREACHABLE,
      error: "the approval was denied",
    });
    mount(
      <MineSubmitDialog
        path={row.path}
        open={true}
        onOpenChange={() => {}}
        onSubmitted={() => {}}
      />,
    );
    await settle();

    const alert = document.body.querySelector('[role="alert"]');
    expect(alert?.textContent).toBe("the approval was denied");
  });
});

// The submit is the one place a person meets an expired sign-in on this
// tab, and the credential is already gone by the time the refusal lands.
// Read as a message it would leave the dialog offering a submit that
// cannot go out, and the sidebar naming an account nobody is signed in
// to any more.
describe("a submit that meets an expired sign-in", () => {
  beforeEach(() => {
    readyToSubmit();
    vi.mocked(commands.mineSubmit).mockResolvedValue({
      status: "error",
      error: { kind: "expired", message: EXPIRED },
    } as never);
  });

  const submit = async () => {
    showDialog();
    await settle();
    const offered = button("Submit");
    expect(offered).toBeDefined();
    await userEvent.click(offered as HTMLButtonElement);
    await settle();
  };

  it("moves the account to expired and drops the rows with it", async () => {
    await submit();
    expect(useAccountStore.getState().account).toEqual({ kind: "expired" });
    expect(useAccountStore.getState().submissions).toBeNull();
  });

  it("stops offering the submit and offers the sign-in that fixes it", async () => {
    await submit();
    expect(button("Submit")).toBeUndefined();
    expect(button("Sign in with GitHub")).toBeDefined();
  });

  it("says what happened, in the sentence the backend sent", async () => {
    await submit();
    const alert = document.body.querySelector('[role="alert"]');
    expect(alert?.textContent).toBe(EXPIRED);
  });
});

// Everything else a submit can be refused for is about the submit. The
// account is not news, and signing the person out over a repository the
// server would not take is a lie the sidebar would then tell.
describe("a submit refused for any other reason", () => {
  it("shows the refusal and leaves the account where it was", async () => {
    const REFUSED = "you cannot push to jane/team-skills";
    readyToSubmit();
    vi.mocked(commands.mineSubmit).mockResolvedValue({
      status: "error",
      error: { kind: "failed", message: REFUSED },
    } as never);
    showDialog();
    await settle();
    await userEvent.click(button("Submit") as HTMLButtonElement);
    await settle();

    expect(document.body.querySelector('[role="alert"]')?.textContent).toBe(
      REFUSED,
    );
    expect(useAccountStore.getState().account).toEqual({
      kind: "signed-in",
      identity: JANE,
    });
    expect(useAccountStore.getState().submissions).toEqual([]);
  });
});
