// @vitest-environment jsdom
// The three questions a write leaves behind are all mounted once in
// App.tsx and can become answerable together: a guided install into a
// project writes files, so the same run can raise a repository effect and
// a commit offer while it is still saying where the packages went.
//
// Each case holds the earlier question open, because that is the state the
// ordering is about — asserted after it closes, a dialog that never waited
// would pass.
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Disclosure, ProjectOffer, Scope } from "@/bindings";
import { commands } from "@/bindings";
import { CommitOfferDialog } from "@/components/commit-offer-dialog";
import { RepoEffectsDialog } from "@/components/marketplaces/repo-effects-dialog";
import { repoEffectsTitle } from "@/lib/copy-repo-effects";
import { useCommitOfferStore } from "@/stores/commit-offer";
import { useInstallFlow } from "@/stores/install-flow";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { useProblemsStore } from "@/stores/problems";
import { mount, settle } from "@/test/dom";

vi.mock("@/bindings", () => ({
  commands: { commitOfferScan: vi.fn() },
}));
vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), info: vi.fn(), message: vi.fn() },
}));

const PROJECT: Scope = { scope: "project", root: "/work/acme" };

const guards = {
  declared: {
    name: "guards",
    root: "/work/acme/.agents/skills/guards",
    summary: "guards arms hooks",
    writes: [".git/hooks/pre-commit"],
    installer: "scripts/arm",
    uninstaller: null,
    undo: null,
    notes: [],
    companions: [],
  },
  name: "guards",
  summary: "Arms git hooks.",
  writes: [{ path: "/work/acme/.git/hooks/pre-commit", shared: false }],
  companions: [],
  notes: [],
  undo: null,
} as unknown as Disclosure;

const offer = {
  root: "/work/acme",
  name: "acme",
  files: ["skills/gh/SKILL.md"],
  message: "add gh",
  branch: null,
  push: null,
  pullRequest: null,
  openNumber: null,
  shared: [],
} as unknown as ProjectOffer;

/** An install still on screen: its ask is open until the reader closes it. */
const installing = () =>
  useInstallFlow.setState({
    ask: { subjects: [] },
    outcome: null,
    running: false,
  });

beforeEach(() => {
  vi.clearAllMocks();
  useInstallFlow.setState({ ask: null, outcome: null, running: false });
  useMarketplacesStore.setState({ pendingEffects: null, busy: false });
  useCommitOfferStore.setState({
    queue: [],
    flagged: [],
    stage: { at: "offer" },
    route: "commit",
    message: "",
    scanFailure: null,
  });
  useProblemsStore.getState().closeError();
});

describe("the questions a write leaves behind", () => {
  // The install writes into each place in turn and reports the whole run
  // once. A package's repository effect arriving mid-run would put a
  // second modal over an install that has not said what it did.
  it("asks about repository effects only once the install is done", async () => {
    installing();
    useMarketplacesStore.setState({
      pendingEffects: { queue: [{ scope: PROJECT, disclosure: guards }] },
    });
    const host = mount(<RepoEffectsDialog />);
    await settle();
    expect(host.ownerDocument.body.textContent).not.toContain(
      repoEffectsTitle("guards"),
    );

    useInstallFlow.getState().close();
    await settle();
    expect(host.ownerDocument.body.textContent).toContain(
      repoEffectsTitle("guards"),
    );
  });

  // Last in the order, so it waits for both. Installing into a project
  // writes files a git project has not committed, which is exactly when
  // all three can be answerable at once.
  it("asks what to do with the files only once both are done", async () => {
    installing();
    useMarketplacesStore.setState({
      pendingEffects: { queue: [{ scope: PROJECT, disclosure: guards }] },
    });
    useCommitOfferStore.setState({ queue: [offer] });
    const host = mount(<CommitOfferDialog />);
    await settle();
    expect(host.ownerDocument.body.textContent).not.toContain("acme");

    // The install closes; the repository effect is still waiting.
    useInstallFlow.getState().close();
    await settle();
    expect(host.ownerDocument.body.textContent).not.toContain("acme");

    useMarketplacesStore.setState({ pendingEffects: null });
    await settle();
    expect(host.ownerDocument.body.textContent).toContain("acme");
  });

  // The scan runs inside the write's own `finally`, so it can fail while
  // the install is still on screen. Its failure is this question's, and
  // waits with it rather than opening the problems dialog over the install
  // that started it.
  it("holds a failed scan until its turn, then says it", async () => {
    vi.mocked(commands.commitOfferScan).mockResolvedValue({
      status: "error",
      error: "git is not on the path",
    });
    installing();
    mount(<CommitOfferDialog />);

    await useCommitOfferStore.getState().enqueue(["/work/acme"]);
    await settle();
    expect(useCommitOfferStore.getState().scanFailure).toBe(
      "git is not on the path",
    );
    expect(useProblemsStore.getState().dialog.open).toBe(false);

    useInstallFlow.getState().close();
    await settle();
    expect(useProblemsStore.getState().dialog.open).toBe(true);
    expect(useProblemsStore.getState().dialog.message).toBe(
      "git is not on the path",
    );
    // Said once: the holding is cleared by the saying.
    expect(useCommitOfferStore.getState().scanFailure).toBeNull();
  });
});
