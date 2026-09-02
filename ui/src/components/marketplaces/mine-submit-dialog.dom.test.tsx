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

/** The name core mints for a sign-in; two answers about one
 *  credential carry the same one. */

vi.mock("@/bindings", () => ({
  commands: {
    mineSubmit: vi.fn(),
    mineSubmitPreflight: vi.fn(),
    accountLoginStart: vi.fn(),
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

// Two things on this tab meet an expired sign-in. This is the one a
// person meets directly, with the refusal's own sentence to show for it;
// the submissions poll meets it with nothing of its own. Read as a
// message it would leave the dialog offering a submit that cannot go
// out, and the sidebar naming an account nobody is signed in to any
// more.
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
    expect(useAccountStore.getState().account).toEqual({
      kind: "expired",
    });
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

// A transport failure folds into the refusal's place as the message alone,
// which is neither arm of `AccountCallRefused`. Read for a `message` field
// it answers `undefined`, the alert renders nothing, and the click reads as
// having done nothing at all — the silence this seam exists to end. It is
// also news about the channel rather than the credential, so it must not
// take the account down with it.
describe("a submit whose transport failed", () => {
  const GONE = "the channel is gone";

  beforeEach(() => {
    readyToSubmit();
    vi.mocked(commands.mineSubmit).mockResolvedValue({
      status: "error",
      error: GONE,
    } as never);
  });

  it("shows the transport's own words and leaves the account signed in", async () => {
    showDialog();
    await settle();
    await userEvent.click(button("Submit") as HTMLButtonElement);
    await settle();

    expect(document.body.querySelector('[role="alert"]')?.textContent).toBe(
      GONE,
    );
    expect(useAccountStore.getState().account).not.toEqual({
      kind: "expired",
    });
  });
});

// The refusal offers a sign-in, and the sign-in can fail in its own
// right. Two sentences then want the one alert, and the expiry is the
// wrong one: it has been acted on, its remedy is the button just
// pressed, and what stopped the person now is the device flow.
describe("the sign-in the expired dialog offers", () => {
  const UNSTARTABLE = "kendex.ai could not start the sign-in";

  const submitThenSignIn = async () => {
    readyToSubmit();
    vi.mocked(commands.mineSubmit).mockResolvedValue({
      status: "error",
      error: { kind: "expired", message: EXPIRED },
    } as never);
    showDialog();
    await settle();
    await userEvent.click(button("Submit") as HTMLButtonElement);
    await settle();
    await userEvent.click(button("Sign in with GitHub") as HTMLButtonElement);
    await settle();
  };

  it("shows the device flow's failure instead of the expiry it replaced", async () => {
    vi.mocked(commands.accountLoginStart).mockResolvedValue({
      status: "error",
      error: UNSTARTABLE,
    } as never);
    await submitThenSignIn();

    expect(document.body.querySelector('[role="alert"]')?.textContent).toBe(
      UNSTARTABLE,
    );
  });

  it("takes the expiry off the screen while the sign-in is out", async () => {
    // Nothing has failed yet, so there is nothing to say. Left standing,
    // the expiry would tell someone waiting on an approval to go and run
    // the command that approval is replacing.
    vi.mocked(commands.accountLoginStart).mockReturnValue(
      new Promise(() => {}) as never,
    );
    await submitThenSignIn();

    expect(document.body.querySelector('[role="alert"]')).toBeNull();
    expect(button("Waiting for approval…")).toBeDefined();
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
