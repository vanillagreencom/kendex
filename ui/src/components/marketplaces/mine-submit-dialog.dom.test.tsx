// @vitest-environment jsdom
// Signed in from the terminal, first launch with kendex.ai unreachable:
// the read fails with no identity to fall back on, so the account is
// still unknown and the dialog offers a sign-in. The reason it is
// offering one has to be on screen with it.
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
