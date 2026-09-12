// @vitest-environment jsdom
import { act } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ProjectOffer, Refused } from "@/bindings";
import { EARLIER_WORD } from "@/components/project-changes/change-rows";
import {
  ACCEPT_EARLIER_LABEL,
  ACCEPT_EARLIER_ONLY,
  ACTION_SEGMENT,
  ALL_SEGMENT,
  COMMIT_LABEL,
  TANGLED_LABEL,
} from "@/lib/copy-commit-offer";
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

// The box holding a program's words is about twelve lines tall and
// scrolls. git and gh write their refusal under whatever a hook printed on
// the way, so a box left at the top opens on the hook and puts the reason
// below the fold. jsdom lays nothing out and reports every height as zero,
// so the room is supplied here, the way the ResizeObserver stub supplies a
// width.
describe("the box holding what a program said", () => {
  const ROOM = 500;

  beforeEach(() => {
    Object.defineProperty(HTMLPreElement.prototype, "scrollHeight", {
      configurable: true,
      get: () => ROOM,
    });
  });

  afterEach(() => {
    Reflect.deleteProperty(HTMLPreElement.prototype, "scrollHeight");
  });

  const pushRefused = (said: string[], timedOut: boolean) => ({
    at: "pushRefused" as const,
    refused: { step: "the push", said, timedOut, seconds: 30, gh: false },
    sha: "c9517af",
    branch: "main",
    files: 1,
    canOpen: false,
    before: null,
  });

  // One mounted tree through both cases. A step that ran out of time has no
  // words and so no box, and the words and the bound reach the same tree
  // position: drawn from separate mounts, neither case would see the other.
  it("opens at its end, and is absent where the step ran out of time", async () => {
    useCommitOfferStore.setState({
      stage: pushRefused(
        [
          "pre-push: lane changelog ok",
          "pre-push: result=0",
          "error: failed to push some refs to 'git@github.com:acme/site.git'",
        ],
        false,
      ),
    });
    const host = mount(<CommitOfferDialog />);
    await settle();

    const box = host.ownerDocument.body.querySelector("pre");
    expect(box, "no box holding the words").not.toBeNull();
    expect((box as HTMLPreElement).scrollTop).toBe(ROOM);
    expect(box?.textContent).toContain("error: failed to push some refs");

    await act(async () => {
      useCommitOfferStore.setState({ stage: pushRefused([], true) });
    });
    await settle();

    expect(host.ownerDocument.body.querySelector("pre")).toBeNull();
    expect(host.ownerDocument.body.textContent).toContain("30");
  });

  // The commit path is the other direction, and it has to stay where it
  // was. git sends a commit hook's stdout to its own stderr, so the
  // reorder leaves those words untouched: the last line is the chain
  // saying the commit was blocked, with the lanes that failed above it.
  it("stays at its top where the commit was refused", async () => {
    useCommitOfferStore.setState({
      stage: {
        at: "commitRefused",
        refused: {
          step: "the commit",
          said: [
            "changelog-entries: the fragment exceeds the character cap",
            "pre-commit: violations \u2014 commit blocked; see the failures above",
          ],
          timedOut: false,
          seconds: 30,
          gh: false,
        },
        stillStaged: null,
        abandoned: true,
        notPutBack: null,
      },
    });
    const host = mount(<CommitOfferDialog />);
    await settle();

    const box = host.ownerDocument.body.querySelector("pre");
    expect(box, "no box holding the words").not.toBeNull();
    expect((box as HTMLPreElement).scrollTop).toBe(0);
    expect(box?.textContent).toContain("changelog-entries");
  });
});

// Every pending path is one the action touched, so there is no selection to
// draw — and the one commit on offer still carries changes the reader did
// not make. The answer that frees it has to be on screen, or the primary
// action is a dead end.
// An offer a person opened themselves has no action behind it. The backend
// spells that as `older` on every file, which through the words would badge
// every row of their own review "Earlier" — their pending work reported as
// some write they cannot see.
describe("a review nobody's write opened", () => {
  const opened: ProjectOffer = {
    ...offer,
    actionPaths: [],
    files: [
      { path: ".claude/CLAUDE.md", did: "older", added: false, removed: false },
    ],
  };

  it("puts no word about an action on any row", async () => {
    useCommitOfferStore.setState({ queue: [opened], scoped: "all" });
    const host = mount(<CommitOfferDialog />);
    await settle();
    // The tree draws a path as its segments, so the file is named by its
    // last one.
    expect(host.ownerDocument.body.textContent).toContain("CLAUDE.md");
    expect(host.ownerDocument.body.textContent).not.toContain(EARLIER_WORD);
  });

  // And a write that did reach the project still says what it did.
  it("keeps the words where a write is behind the offer", async () => {
    useCommitOfferStore.setState({
      queue: [{ ...opened, actionPaths: [".claude/CLAUDE.md"] }],
      scoped: "all",
    });
    const host = mount(<CommitOfferDialog />);
    await settle();
    expect(host.ownerDocument.body.textContent).toContain(EARLIER_WORD);
  });
});

// The segments are buttons that hold a selection, so which one is chosen
// has to reach a screen reader. Drawn state alone says it to sighted
// readers only, and the repo draws its other choice controls this way.
describe("the which-changes segments", () => {
  it("says which segment is chosen", async () => {
    useCommitOfferStore.setState({
      queue: [{ ...offer, choice: true, actionPaths: [".claude/CLAUDE.md"] }],
      scoped: "action",
    });
    const host = mount(<CommitOfferDialog />);
    await settle();
    const pressed = [
      ...host.ownerDocument.body.querySelectorAll("button[aria-pressed]"),
    ].map((one) => [one.textContent, one.getAttribute("aria-pressed")]);
    expect(pressed).toEqual([
      [ACTION_SEGMENT, "true"],
      [ALL_SEGMENT, "false"],
    ]);
  });
});

describe("an offer whose files all carry earlier changes", () => {
  const both: ProjectOffer = {
    ...offer,
    choice: false,
    files: [
      { path: ".claude/CLAUDE.md", did: "both", added: false, removed: false },
    ],
    tangled: [{ path: ".claude/CLAUDE.md", reason: "carriesEarlier" }],
  };

  it("asks for the yes on screen and commits once it is given", async () => {
    useCommitOfferStore.setState({
      queue: [both],
      scoped: "action",
      accepted: false,
    });
    const host = mount(<CommitOfferDialog />);
    await settle();
    const primary = () =>
      [...host.ownerDocument.body.querySelectorAll("button")]
        .filter((one) => one.textContent === COMMIT_LABEL)
        .at(-1) as HTMLButtonElement;
    expect(primary(), buttons().join(" | ")).toBeDefined();
    expect(primary().disabled).toBe(true);
    // The reader is told what the commit carries, and why it is held.
    expect(host.ownerDocument.body.textContent).toContain(TANGLED_LABEL);
    expect(host.ownerDocument.body.textContent).toContain(".claude/CLAUDE.md");
    expect(host.ownerDocument.body.textContent).toContain(ACCEPT_EARLIER_ONLY);

    // The control that takes the answer is here, in the branch with no
    // selection: this is the dead end the state used to be.
    const box = host.ownerDocument.body.querySelector(
      `[aria-label="${ACCEPT_EARLIER_LABEL}"]`,
    );
    expect(box, "no way to answer").not.toBeNull();
    await act(async () => {
      (box as HTMLElement).click();
    });
    await settle();
    expect(primary().disabled).toBe(false);
  });
});
