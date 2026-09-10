// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ProjectOffer, Refused } from "@/bindings";
import { COMMIT_LABEL, TANGLED_LABEL } from "@/lib/copy-commit-offer";
import { useCommitOfferStore } from "@/stores/commit-offer";
import { mount, settle } from "@/test/dom";
import { CommitOfferDialog } from "./commit-offer-dialog";

vi.mock("@/bindings", () => ({ commands: {} }));
vi.mock("sonner", () => ({ toast: { info: vi.fn(), success: vi.fn() } }));

const offer: ProjectOffer = {
  root: "/home/method/dev/site",
  name: "site",
  files: [
    { path: ".claude/CLAUDE.md", did: "action", added: false, removed: false },
  ],
  actionPaths: [".claude/CLAUDE.md"],
  choice: false,
  tangled: [],
  shared: [],
  manifest: null,
  others: 0,
  branch: "main",
  remote: "origin",
  push: null,
  pullRequest: null,
  openNumber: null,
  message: "chore: kendex refresh",
  newBranch: "kendex/renders",
  repo: "acme/site",
  tracked: true,
};

const refused = (step: string, said: string): Refused => ({
  step,
  said: [said],
  timedOut: false,
  seconds: 30,
  gh: false,
});

const buttons = () =>
  [...document.body.querySelectorAll("button")].map((one) => one.textContent);

beforeEach(() => {
  useCommitOfferStore.setState({
    queue: [offer],
    stage: { at: "offer" },
    route: "commit",
    scoped: "action",
    accepted: false,
    message: offer.message,
  });
});

describe("the branch-not-made state", () => {
  it("offers the segments again without the pull request", async () => {
    useCommitOfferStore.setState({
      stage: {
        at: "branchRefused",
        refused: refused(
          "the branch",
          "fatal: a branch named 'kendex/renders' already exists",
        ),
      },
      route: "commit",
    });
    mount(<CommitOfferDialog />);
    await settle();

    const text = document.body.textContent ?? "";
    expect(text).toContain("The branch could not be made");
    expect(text).toContain(
      "fatal: a branch named 'kendex/renders' already exists",
    );
    expect(text).toContain(
      "Nothing was committed and this checkout has not moved.",
    );
    const labels = buttons();
    expect(labels).toContain("Commit and push");
    expect(labels).not.toContain("Pull request");
    expect(labels).toContain("Leave as diffs");
    expect(labels.filter((one) => one === "Commit")).toHaveLength(2);
  });

  it("follows the picked segment on its primary button", async () => {
    useCommitOfferStore.setState({
      stage: { at: "branchRefused", refused: refused("the branch", "no") },
      route: "push",
    });
    mount(<CommitOfferDialog />);
    await settle();

    expect(document.body.textContent).toContain("Pushes to origin/main.");
    expect(buttons().filter((one) => one === "Commit and push")).toHaveLength(
      2,
    );
  });
});

describe("the commit refused where the checkout could not be put back", () => {
  it("shows both refusals and offers only to leave", async () => {
    useCommitOfferStore.setState({
      stage: {
        at: "commitRefused",
        refused: refused(
          "the commit",
          "commit-msg: crates/ changed without a changelog entry",
        ),
        stillStaged: null,
        abandoned: false,
        notPutBack: refused(
          "the switch back",
          "error: Your local changes would be overwritten by checkout",
        ),
      },
    });
    mount(<CommitOfferDialog />);
    await settle();

    const text = document.body.textContent ?? "";
    expect(text).toContain("The commit was refused");
    expect(text).toContain(
      "commit-msg: crates/ changed without a changelog entry",
    );
    expect(text).toContain("The checkout could not be put back.");
    expect(text).toContain(
      "error: Your local changes would be overwritten by checkout",
    );
    expect(text).not.toContain("is gone.");
    const labels = buttons();
    expect(labels).toContain("Leave as diffs");
    expect(labels).not.toContain("Commit again");
  });

  it("names only the switch back where nothing was left to commit", async () => {
    useCommitOfferStore.setState({
      stage: {
        at: "notPutBack",
        refused: refused("the switch back", "error: cannot switch branch"),
      },
    });
    mount(<CommitOfferDialog />);
    await settle();

    const text = document.body.textContent ?? "";
    expect(text).toContain("The checkout could not be put back");
    expect(text).toContain("Nothing to commit");
    expect(text).toContain("error: cannot switch branch");
    expect(text).not.toContain("The commit was refused");
    const labels = buttons();
    expect(labels).toContain("Leave as diffs");
    expect(labels).not.toContain("Commit again");
  });

  it("offers to commit again where the checkout is back", async () => {
    useCommitOfferStore.setState({
      stage: {
        at: "commitRefused",
        refused: refused("the commit", "commit-msg: no"),
        stillStaged: null,
        abandoned: true,
        notPutBack: null,
      },
    });
    mount(<CommitOfferDialog />);
    await settle();

    expect(document.body.textContent).toContain(
      "This checkout is back on main and kendex/renders is gone.",
    );
    expect(buttons()).toContain("Commit again");
  });
});

// The state item 2 named: every pending path is one the action touched, so
// there is no choice to draw — and the controls that could answer a tangle
// live inside that choice. The primary action has to stay reachable.
describe("an offer whose files all carry earlier changes", () => {
  const both: ProjectOffer = {
    ...offer,
    choice: false,
    files: [
      { path: ".claude/CLAUDE.md", did: "both", added: false, removed: false },
    ],
    tangled: [{ path: ".claude/CLAUDE.md", reason: "carriesEarlier" }],
  };

  it("keeps the commit reachable and still names the files", async () => {
    useCommitOfferStore.setState({ queue: [both], scoped: "action" });
    const host = mount(<CommitOfferDialog />);
    await settle();
    const primary = [...host.ownerDocument.body.querySelectorAll("button")]
      .filter((one) => one.textContent === COMMIT_LABEL)
      .at(-1);
    expect(primary, buttons().join(" | ")).toBeDefined();
    expect((primary as HTMLButtonElement).disabled).toBe(false);
    // The reader is still told what the commit carries.
    expect(host.ownerDocument.body.textContent).toContain(TANGLED_LABEL);
    expect(host.ownerDocument.body.textContent).toContain(".claude/CLAUDE.md");
  });
});
