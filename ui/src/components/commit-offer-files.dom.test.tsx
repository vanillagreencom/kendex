// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { FileChanges } from "@/bindings";
import { commands } from "@/bindings";
import {
  CHANGES_READ_FAILED_TITLE,
  didNotFinish,
  SAME_CONTENT_NOTE,
} from "@/lib/copy-commit-offer";
import { UNCHANGED_FILE_NOTE } from "@/lib/copy-files";
import { mount, settle } from "@/test/dom";
import { CommitOfferFiles } from "./commit-offer-files";

vi.mock("@/bindings", () => ({
  commands: { commitOfferFileChanges: vi.fn() },
}));

const ROOT = "/home/method/dev/site";
const paths = [".claude/skills/gh/SKILL.md", ".claude/CLAUDE.md"];

const shown = (text: string): FileChanges => ({
  kind: "shown",
  diff: {
    files: [
      {
        path: ".claude/CLAUDE.md",
        status: "modified",
        additions: 1,
        deletions: 0,
        lossy: false,
        hunks: [
          {
            header: "@@ -1 +1 @@",
            lines: [{ kind: "add", text, oldNo: null, newNo: 1 }],
          },
        ],
      },
    ],
    totalAdditions: 1,
    totalDeletions: 0,
    truncated: false,
  },
});

const answers = (data: FileChanges) =>
  vi
    .mocked(commands.commitOfferFileChanges)
    .mockResolvedValue({ status: "ok", data });

const render = () => mount(<CommitOfferFiles root={ROOT} paths={paths} />);

/** A tree row by the path it names, read off the document: the panel this
 *  component opens is portalled out of the tree it mounted into. */
const rowFor = (path: string) =>
  [...document.body.querySelectorAll("button")].find(
    (one) => one.title === path,
  ) as HTMLElement;

/** The panel is portalled out of the tree the component mounted into. */
const panel = () => document.body.textContent ?? "";

const open = async (path: string) => {
  await userEvent.click(rowFor(path));
  await settle();
};

beforeEach(() => {
  vi.mocked(commands.commitOfferFileChanges).mockReset();
});

describe("the files a commit would carry", () => {
  it("lists them as folders and files rather than as bare paths", () => {
    render();
    expect(rowFor(".claude/skills")).toBeDefined();
    expect(rowFor(".claude/skills/gh/SKILL.md")).toBeDefined();
  });

  it("opens the picked file's diff, asking about that file in this project", async () => {
    answers(shown("A-LINE-KENDEX-WROTE"));
    render();
    await open(".claude/CLAUDE.md");

    expect(vi.mocked(commands.commitOfferFileChanges).mock.calls).toEqual([
      [ROOT, ".claude/CLAUDE.md"],
    ]);
    expect(panel()).toContain("A-LINE-KENDEX-WROTE");
  });

  // The offer is re-read when a file is opened, and a file the fresh read
  // no longer covers has no diff to show. Saying so is the answer; drawing
  // an empty comparison would read as "nothing changed here" about a file
  // still on the list.
  it("says a file the offer no longer covers has nothing left to show", async () => {
    answers({ kind: "nothing" });
    render();
    await open(".claude/CLAUDE.md");
    expect(panel()).toContain(UNCHANGED_FILE_NOTE);
  });

  // git carries changes the contents do not show — a registration script
  // regaining its execute bit is one kendex itself makes. Drawing that as
  // an empty comparison would tell the person nothing changed in a file
  // the commit does change.
  it("says what a change the contents do not show is", async () => {
    answers({ kind: "sameContent" });
    render();
    await open(".claude/CLAUDE.md");
    expect(panel()).toContain(SAME_CONTENT_NOTE);
  });

  // The must-not-happen half: a read that failed is never drawn as a diff
  // with no changes in it.
  it("shows a refused read's own words", async () => {
    answers({
      kind: "refused",
      refused: {
        step: "the read",
        said: ["fatal: not a git repository"],
        timedOut: false,
        seconds: 30,
        gh: false,
      },
    });
    render();
    await open(".claude/CLAUDE.md");
    expect(panel()).toContain(CHANGES_READ_FAILED_TITLE);
    expect(panel()).toContain("fatal: not a git repository");
  });

  // A read that ran out of time said nothing, so its own words are empty;
  // the panel says what it stopped waiting for instead of showing a blank
  // failure.
  it("says what a timed-out read stopped waiting for", async () => {
    answers({
      kind: "refused",
      refused: {
        step: "the read",
        said: [],
        timedOut: true,
        seconds: 30,
        gh: false,
      },
    });
    render();
    await open(".claude/CLAUDE.md");
    expect(panel()).toContain(didNotFinish(30));
  });
});
