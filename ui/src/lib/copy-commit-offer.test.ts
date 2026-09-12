import { describe, expect, it } from "vitest";
import type { Refused } from "@/bindings";
import {
  addsToPullRequest,
  backOn,
  branchIsOn,
  commitIsOn,
  commitOfferTitle,
  commitOn,
  commitRefusedTitle,
  committedToast,
  didNotFinish,
  notChecked,
  nowOn,
  otherNote,
  prMoves,
  pullRequestRefusedTitle,
  pushedToast,
  pushesTo,
  pushRefusedTitle,
  putBackRowLabel,
  remoteBranch,
  resetCommand,
  saidLabel,
  stillCarries,
  stillStaged,
  unavailableReason,
  uncommittedBadge,
  uncommittedInProgress,
  uncommittedNoBranch,
} from "./copy-commit-offer";

// The design's example values, `docs/design/post-refresh-commit-flow.md`
// § App: every string below is the one its table prints for them.
const FILES = 12;
const OTHERS = 4;
const PROJECT = "site";
const REMOTE = "origin";
const BRANCH = "main";
const NEW_BRANCH = "kendex/renders";
const SHA = "9fbb1a2";
const NUMBER = 41;
const BEFORE = "4c1d90e";
const SECONDS = 300;

const refused = (over: Partial<Refused> = {}): Refused => ({
  step: "the commit",
  said: ["commit-msg: crates/ changed without a changelog entry"],
  timedOut: false,
  seconds: SECONDS,
  gh: false,
  ...over,
});

describe("the offer state", () => {
  it("prints the design's words for its example values", () => {
    expect(commitOfferTitle(FILES, PROJECT)).toBe(
      "12 files kendex wrote in site are not committed",
    );
    expect(commitOfferTitle(1, PROJECT)).toBe(
      "1 file kendex wrote in site is not committed",
    );
    expect(otherNote(OTHERS)).toBe(
      "4 other files in this repository changed. kendex does not commit these.",
    );
    expect(otherNote(1)).toBe(
      "1 other file in this repository changed. kendex does not commit these.",
    );
    expect(pushesTo(REMOTE, BRANCH)).toBe("Pushes to origin/main.");
    expect(addsToPullRequest(NUMBER)).toBe(
      "Adds a commit to pull request #41.",
    );
    expect(prMoves(NEW_BRANCH, BRANCH)).toBe(
      "Commits on kendex/renders and opens a pull request. This checkout moves to that branch. main stays where it is.",
    );
  });
});

describe("the rows for a segment a precondition removed", () => {
  // The `ghSaid` row is gh's own first line, not the design's fixed
  // `gh is not signed in. Run gh auth login.`: kendex does not decide what
  // gh meant.
  it("labels the row and names the reason", () => {
    expect(unavailableReason({ kind: "noRemote" })).toBe(
      "This repository has no remote.",
    );
    expect(unavailableReason({ kind: "remoteNotDecidable" })).toBe(
      "This branch tracks no remote and the repository has more than one.",
    );
    expect(unavailableReason({ kind: "ghMissing" })).toBe(
      "gh is not installed.",
    );
    expect(
      unavailableReason({
        kind: "ghSaid",
        line: "To get started with GitHub CLI, please run:  gh auth login",
      }),
    ).toBe("To get started with GitHub CLI, please run:  gh auth login");
  });
});

describe("the result states", () => {
  it("toasts the two that close and draws the pull request", () => {
    expect(committedToast(FILES)).toBe("Committed 12 files");
    expect(committedToast(1)).toBe("Committed 1 file");
    expect(pushedToast(FILES)).toBe("Committed and pushed 12 files");
    expect(commitOn(SHA, NEW_BRANCH)).toBe("9fbb1a2 on kendex/renders");
    expect(nowOn(NEW_BRANCH)).toBe("This checkout is now on kendex/renders.");
    // The refused-push recovery's two added rows.
    expect(stillCarries(BRANCH)).toBe(
      "main in this checkout still carries the commit.",
    );
    expect(putBackRowLabel(BRANCH)).toBe("To put main back");
    expect(resetCommand(BEFORE)).toBe("git reset --mixed 4c1d90e");
  });
});

describe("the refusal states", () => {
  it("prints each title, section heading, line and footer", () => {
    expect(commitRefusedTitle(refused())).toBe("The commit was refused");
    expect(commitRefusedTitle(refused({ step: "the check" }))).toBe(
      "The files could not be checked",
    );
    expect(commitRefusedTitle(refused({ step: "the staging" }))).toBe(
      "The files could not be staged",
    );
    expect(saidLabel(refused())).toBe("What git said");
    expect(saidLabel(refused({ gh: true }))).toBe("What gh said");
    expect(stillStaged(OTHERS)).toBe(
      "kendex staged 4 files it could not unstage. They are still staged.",
    );
    expect(backOn(BRANCH, NEW_BRANCH)).toBe(
      "This checkout is back on main and kendex/renders is gone.",
    );
    expect(pushRefusedTitle(refused({ step: "the push" }))).toBe(
      "Committed, not pushed",
    );
    expect(commitOn(SHA, BRANCH)).toBe("9fbb1a2 on main");
    expect(commitIsOn(BRANCH)).toBe(
      "The commit is on main in this checkout. kendex did not undo it.",
    );
    expect(pullRequestRefusedTitle(refused({ step: "the pull request" }))).toBe(
      "Committed and pushed, no pull request",
    );
    expect(remoteBranch(REMOTE, NEW_BRANCH)).toBe("origin/kendex/renders");
    expect(branchIsOn(REMOTE)).toBe(
      "The branch is on origin. Open the pull request yourself.",
    );
  });
});

describe("a step that timed out", () => {
  it("turns the title's verb and replaces the section with one line", () => {
    const out = { timedOut: true, said: [] };
    expect(commitRefusedTitle(refused({ ...out, step: "the commit" }))).toBe(
      "The commit did not finish",
    );
    expect(pushRefusedTitle(refused({ ...out, step: "the push" }))).toBe(
      "The push did not finish",
    );
    expect(
      pullRequestRefusedTitle(refused({ ...out, step: "the pull request" })),
    ).toBe("The pull request did not finish");
    expect(didNotFinish(SECONDS)).toBe(
      "kendex stopped waiting after 300 seconds. Whether it finished is not known here.",
    );
    expect(didNotFinish(1)).toBe(
      "kendex stopped waiting after 1 second. Whether it finished is not known here.",
    );
  });
});

describe("the project card where no offer can be made", () => {
  it("draws the badge and puts the reason on hover", () => {
    expect(uncommittedBadge(FILES)).toBe("12 uncommitted");
    expect(uncommittedNoBranch(FILES)).toBe(
      "12 files kendex wrote are not committed. This checkout is on no branch.",
    );
    expect(uncommittedNoBranch(1)).toBe(
      "1 file kendex wrote is not committed. This checkout is on no branch.",
    );
    expect(uncommittedInProgress(FILES, "a rebase")).toBe(
      "12 files kendex wrote are not committed. A rebase is in progress.",
    );
    expect(notChecked(["fatal: not a git repository"])).toBe(
      "kendex could not check the files it wrote here. git said: fatal: not a git repository",
    );
    expect(notChecked([])).toBe(
      "kendex could not check the files it wrote here.",
    );
  });
});
