// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act, useState } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { FileChanges, FileMode } from "@/bindings";
import { commands } from "@/bindings";
import {
  CHANGES_READ_FAILED_TITLE,
  didNotFinish,
  modeChangeNote,
  SAME_CONTENT_NOTE,
} from "@/lib/copy-commit-offer";
import { CLOSE_CHANGES_LABEL, UNCHANGED_FILE_NOTE } from "@/lib/copy-files";
import { mount, settle } from "@/test/dom";
import { pathEntries } from "./change-rows";
import { ChangedFiles } from "./changed-files";

vi.mock("@/bindings", () => ({
  commands: { commitOfferFileChanges: vi.fn() },
}));

const ROOT = "/home/method/dev/site";
const paths = [".claude/skills/gh/SKILL.md", ".claude/CLAUDE.md"];

type Mode = FileMode | null;

const shown = (text: string, mode: Mode = null): FileChanges =>
  ({
    kind: "shown",
    mode,
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
  }) as FileChanges;

/** A comparison with nothing in it, for the states where the contents do
 *  not move. */
const noContentChange = (mode: Mode): FileChanges => ({
  kind: "shown",
  mode,
  diff: {
    files: [],
    totalAdditions: 0,
    totalDeletions: 0,
    truncated: false,
  },
});

const answers = (data: FileChanges) =>
  vi
    .mocked(commands.commitOfferFileChanges)
    .mockResolvedValue({ status: "ok", data });

/** One read per call, each resolved by hand, so a test decides which of
 *  several reads out at once lands first. */
const answersInTurn = () => {
  const waiting: ((data: FileChanges) => void)[] = [];
  vi.mocked(commands.commitOfferFileChanges).mockImplementation(
    () =>
      new Promise((resolve) => {
        waiting.push((data) => resolve({ status: "ok", data }));
      }),
  );
  return waiting;
};

const render = () =>
  mount(<ChangedFiles root={ROOT} entries={pathEntries(paths)} />);

/** A tree row by the path it names, read off the document: the panel this
 *  component opens is portalled out of the tree it mounted into. */
const rowFor = (path: string) =>
  [...document.body.querySelectorAll("button")].find(
    (one) => one.title === path,
  ) as HTMLElement;

/** The panel is portalled out of the tree the component mounted into. */
const panel = () => document.body.textContent ?? "";

/** The panel's own close control. */
const closeButton = () =>
  [...document.body.querySelectorAll("button")].find(
    (one) => one.getAttribute("aria-label") === CLOSE_CHANGES_LABEL,
  ) as HTMLElement;

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
  // Putting a file back takes it to what the last commit holds, and the
  // next read of the project carries no row for it. The panel over it was
  // showing a diff that no longer exists, and the caller's record of what
  // is open still named that path — so a button acting on "the open file"
  // acted on one this project holds no change for.
  it("closes the panel when the open file leaves the list", async () => {
    answers(shown("A-LINE-KENDEX-WROTE"));
    let opened: string | null = "unset";
    let reread: (paths: string[]) => void = () => {};
    function Reading() {
      const [listed, set] = useState(paths);
      reread = set;
      return (
        <ChangedFiles
          root={ROOT}
          entries={pathEntries(listed)}
          onOpen={(path) => {
            opened = path;
          }}
        />
      );
    }
    mount(<Reading />);
    await open(".claude/CLAUDE.md");
    expect(panel()).toContain("A-LINE-KENDEX-WROTE");
    expect(opened).toBe(".claude/CLAUDE.md");

    // The project is read again and that file is gone from it.
    await act(async () => {
      reread(paths.filter((path) => path !== ".claude/CLAUDE.md"));
    });
    await settle();
    expect(panel()).not.toContain("A-LINE-KENDEX-WROTE");
    expect(opened, "the caller was left holding a path that is gone").toBe(
      null,
    );
  });

  it("says what a change the contents do not show is", async () => {
    answers(noContentChange({ before: "100644", after: "100755" }));
    render();
    await open(".claude/CLAUDE.md");
    expect(panel()).toContain(SAME_CONTENT_NOTE);
    expect(panel()).toContain(modeChangeNote("100644", "100755"));
  });

  // A commit can rewrite a script and restore its execute bit at once.
  // Reading the mode off the comparison would show the text change and
  // hide the other half; both are on screen.
  it("says the mode change beside a content change, not instead of it", async () => {
    answers(
      shown("A-LINE-KENDEX-WROTE", { before: "100644", after: "100755" }),
    );
    render();
    await open(".claude/CLAUDE.md");
    expect(panel()).toContain("A-LINE-KENDEX-WROTE");
    expect(panel()).toContain(modeChangeNote("100644", "100755"));
    // The contents did move, so the note about them not moving is wrong
    // here and is not drawn.
    expect(panel()).not.toContain(SAME_CONTENT_NOTE);
  });

  // Neither half changed: the file went back to what the last commit holds
  // between the offer being read and the row being opened.
  it("says nothing is left when neither the contents nor the mode moved", async () => {
    answers(noContentChange(null));
    render();
    await open(".claude/CLAUDE.md");
    expect(panel()).toContain(UNCHANGED_FILE_NOTE);
  });

  // Two reads about the same file can be out at once — a person moving
  // A → B → A, or closing the panel and opening it again. The path cannot
  // tell them apart, so the older answer must not land on top of the
  // newer: the project has moved on between the two scans.
  it("lets only the newest read write, even when its file repeats", async () => {
    const waiting = answersInTurn();
    render();
    await open(".claude/CLAUDE.md");
    await open(".claude/skills/gh/SKILL.md");
    await open(".claude/CLAUDE.md");
    expect(waiting).toHaveLength(3);

    // The first read of that file lands last, carrying the older scan.
    await act(async () => waiting[2]?.(shown("THE-NEWEST-ANSWER")));
    await act(async () => waiting[0]?.(shown("AN-OLDER-ANSWER")));
    expect(panel()).toContain("THE-NEWEST-ANSWER");
    expect(panel()).not.toContain("AN-OLDER-ANSWER");
  });

  // Closing and opening the same file again is the same trap wearing a
  // different shape: two reads about one path, and the one from before the
  // panel closed must not land in the panel that replaced it.
  it("lets no read from before a close write into the panel after it", async () => {
    const waiting = answersInTurn();
    render();
    await open(".claude/CLAUDE.md");
    await userEvent.click(closeButton());
    await settle();
    await open(".claude/CLAUDE.md");
    expect(waiting).toHaveLength(2);

    await act(async () =>
      waiting[1]?.(shown("THE-ANSWER-THIS-PANEL-ASKED-FOR")),
    );
    await act(async () =>
      waiting[0]?.(shown("AN-ANSWER-FROM-BEFORE-THE-CLOSE")),
    );
    expect(panel()).toContain("THE-ANSWER-THIS-PANEL-ASKED-FOR");
    expect(panel()).not.toContain("AN-ANSWER-FROM-BEFORE-THE-CLOSE");
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
