// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ProjectChanges } from "@/bindings";
import { commands } from "@/bindings";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import { capitalised, uncommittedInProgress } from "@/lib/copy-commit-offer";
import {
  CHANGES_UNAVAILABLE_TITLE,
  COMMIT_CHANGES_LABEL,
  COULD_NOT_CHECK,
  inProgressHeld,
  LAST_CHECKED_NOTE,
  NO_BRANCH_HELD,
  NOTHING_PENDING,
  PACKAGE_EDITS_LABEL,
  PARTIAL_NOTE,
  projectChangesTitle,
  REMOVED_LABEL,
  RERENDERED_LABEL,
  RERENDERED_NOTE,
  RESTORED_LABEL,
  REVERT_CONFIRM_LABEL,
  REVERT_LABEL,
} from "@/lib/copy-project-changes";
import { READ_LANDED, readFailed } from "@/lib/read-state";
import { useCommitOfferStore } from "@/stores/commit-offer";
import { useNavStore } from "@/stores/nav";
import { useProjectChangesStore } from "@/stores/project-changes";
import { useSettingsStore } from "@/stores/settings";
import { mount, settle } from "@/test/dom";
import { ProjectChangesPage } from "./project-changes";

vi.mock("@/bindings", () => ({
  commands: {
    scanMachine: vi.fn(),
    auditAll: vi.fn(),
    libraryProvenance: vi.fn(),
    projectChangesScan: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
    projectChangesRestorePlan: vi.fn(),
    projectChangesRestore: vi.fn(),
    commitOfferFileChanges: vi.fn(),
    commitOfferOpen: vi.fn(),
  },
}));
vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), info: vi.fn() },
}));

const ROOT = "/home/method/dev/site";
const FILES = [".claude/CLAUDE.md", ".kendex-generated.json"];

const row = (over: Partial<ProjectChanges["state"]> = {}): ProjectChanges => ({
  root: ROOT,
  name: "site",
  state: {
    kind: "pending",
    files: FILES,
    shared: [],
    others: 0,
    branch: "main",
    operation: null,
    ...over,
  } as ProjectChanges["state"],
});

const body = () => document.body.textContent ?? "";

const button = (label: string): HTMLElement => {
  const found = [...document.body.querySelectorAll("button")].find((one) =>
    one.textContent?.includes(label),
  );
  if (!found) throw new Error(`no button says ${label}: ${body()}`);
  return found;
};

beforeEach(() => {
  vi.clearAllMocks();
  useNavStore.setState({
    page: "projectChanges",
    changesRoot: ROOT,
    history: [],
  });
  useProjectChangesStore.setState({ rows: [row()], read: READ_LANDED });
  useCommitOfferStore.setState({ queue: [], baselines: {} });
});

describe("the review of one project's pending changes", () => {
  it("names the project, its branch and its changed files", async () => {
    mount(<ProjectChangesPage />);
    await settle();
    expect(body()).toContain(projectChangesTitle("site"));
    expect(body()).toContain(ROOT);
    expect(body()).toContain("main");
    for (const path of FILES) expect(body()).toContain(path.split("/").pop());
    // The two ways out of a hand edit are explained here, and the commit is
    // named as neither of them.
    expect(body()).toContain(PACKAGE_EDITS_LABEL);
  });

  // A state that allows no commit says which state, in the words the read
  // that refused gave — not in silence, and not from the row this page drew
  // before that read.
  it("says why a commit could not be opened", async () => {
    vi.mocked(commands.commitOfferOpen).mockResolvedValue({
      status: "ok",
      data: {
        kind: "blocked",
        flag: {
          root: ROOT,
          count: 2,
          reason: { kind: "inProgress", operation: "a rebase" },
        },
      },
    });
    mount(<ProjectChangesPage />);
    await settle();
    await userEvent.click(button(COMMIT_CHANGES_LABEL));
    await settle();
    expect(body()).toContain(CHANGES_UNAVAILABLE_TITLE);
    expect(body()).toContain(uncommittedInProgress(2, "a rebase"));
  });

  // Opening the commit is a button, never something this page does by
  // itself. The setting that turns off asking does not reach it: the reader
  // is asking.
  it("opens the commit only when asked, and only for this project", async () => {
    vi.mocked(commands.commitOfferOpen).mockResolvedValue({
      status: "ok",
      data: { kind: "nothing" },
    });
    mount(<ProjectChangesPage />);
    await settle();
    expect(commands.commitOfferOpen).not.toHaveBeenCalled();
    await userEvent.click(button(COMMIT_CHANGES_LABEL));
    await settle();
    expect(commands.commitOfferOpen).toHaveBeenCalledWith(ROOT);
  });

  // The states no commit could land in keep their changes on screen with
  // the reason beside the button, rather than hiding either.
  it("keeps the changes on screen in a state no commit could land in", async () => {
    const rows = [
      {
        name: "no branch",
        state: { branch: null },
        held: NO_BRANCH_HELD,
      },
      {
        name: "mid-rebase",
        state: { operation: "a rebase" },
        held: inProgressHeld(capitalised("a rebase")),
      },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const one of rows) {
      useProjectChangesStore.setState({ rows: [row(one.state)] });
      const host = mount(<ProjectChangesPage />);
      await settle();
      expect(host.ownerDocument.body.textContent, one.name).toContain(one.held);
      expect(host.ownerDocument.body.textContent, one.name).toContain(
        FILES[0].split("/").pop(),
      );
      expect(
        (button(COMMIT_CHANGES_LABEL) as HTMLButtonElement).disabled,
        one.name,
      ).toBe(true);
    }
  });

  // A read that would not run is not zero changes. It says so and offers
  // the read again.
  it("says the read failed rather than drawing the project as clean", async () => {
    useProjectChangesStore.setState({
      rows: [
        {
          root: ROOT,
          name: "site",
          state: { kind: "unreadable", said: ["fatal: bad object HEAD"] },
        },
      ],
    });
    mount(<ProjectChangesPage />);
    await settle();
    expect(body()).toContain(COULD_NOT_CHECK);
    expect(body()).toContain("fatal: bad object HEAD");
    expect(body()).not.toContain(NOTHING_PENDING);
  });

  // A row kept from an earlier read, under a read that has since failed.
  // The files are the last kendex could check, not what is there now, and
  // this page says so and offers the read again — the same rule the card
  // keeps, on the surface the card sends people to.
  it("says the rows are unconfirmed when the re-read failed", async () => {
    useProjectChangesStore.setState({
      rows: [row()],
      read: readFailed("git is not on the path"),
    });
    mount(<ProjectChangesPage />);
    await settle();
    expect(body()).toContain(capitalised(LAST_CHECKED_NOTE));
    expect(body()).toContain("git is not on the path");
    expect(button(TRY_AGAIN_LABEL), "no way to ask again").toBeDefined();
    // The files it does have are still shown: they are the best answer
    // available, and hiding them would lose that.
    expect(body()).toContain(FILES[0].split("/").pop());
  });

  // The folder name comes from the read, which knows this platform's
  // separator. A Windows root holds no `/`, so splitting one here would
  // title the page with the whole path.
  it("titles the page with the folder name, not the path", async () => {
    const windows = "C:\\Users\\p\\dev\\site";
    useNavStore.setState({ changesRoot: windows });
    useProjectChangesStore.setState({
      rows: [{ root: windows, name: "site", state: { kind: "clean" } }],
      read: READ_LANDED,
    });
    mount(<ProjectChangesPage />);
    await settle();
    expect(body()).toContain(projectChangesTitle("site"));
    expect(body()).not.toContain(projectChangesTitle(windows));
  });

  it("says so when nothing is waiting", async () => {
    useProjectChangesStore.setState({
      rows: [{ root: ROOT, name: "site", state: { kind: "clean" } }],
    });
    mount(<ProjectChangesPage />);
    await settle();
    expect(body()).toContain(NOTHING_PENDING);
  });

  // The preview states the exact effect before anything runs, and the run
  // is a second, separate call.
  it("previews putting files back before it puts anything back", async () => {
    vi.mocked(commands.projectChangesRestorePlan).mockResolvedValue({
      status: "ok",
      data: {
        kind: "effect",
        effect: {
          restored: [FILES[0]],
          removed: [FILES[1]],
          dropped: [],
          added: [],
          rerendered: [],
        },
      },
    });
    vi.mocked(commands.projectChangesRestore).mockResolvedValue({
      status: "ok",
      data: {
        kind: "effect",
        effect: {
          restored: [FILES[0]],
          removed: [FILES[1]],
          dropped: [],
          added: [],
          rerendered: [],
        },
      },
    });
    mount(<ProjectChangesPage />);
    await settle();
    await userEvent.click(button(REVERT_LABEL));
    await settle();
    expect(commands.projectChangesRestorePlan).toHaveBeenCalledWith(
      ROOT,
      FILES,
    );
    expect(commands.projectChangesRestore).not.toHaveBeenCalled();
    expect(body()).toContain(RESTORED_LABEL);
    expect(body()).toContain(REMOVED_LABEL);

    await userEvent.click(button(REVERT_CONFIRM_LABEL));
    await settle();
    expect(commands.projectChangesRestore).toHaveBeenCalledWith(ROOT, FILES);
  });

  // Cancelling runs nothing. The preview is a read; the run is a second,
  // separate call, and only the confirm makes it.
  it("puts nothing back when the preview is cancelled", async () => {
    vi.mocked(commands.projectChangesRestorePlan).mockResolvedValue({
      status: "ok",
      data: {
        kind: "effect",
        effect: {
          restored: [FILES[0]],
          removed: [],
          dropped: [],
          added: [],
          rerendered: [],
        },
      },
    });
    mount(<ProjectChangesPage />);
    await settle();
    await userEvent.click(button(REVERT_LABEL));
    await settle();
    await userEvent.click(button("Cancel"));
    await settle();
    expect(commands.projectChangesRestore).not.toHaveBeenCalled();
    expect(body()).not.toContain(RESTORED_LABEL);
  });

  // A refusal keeps the dialog open with git's own words in it: closing
  // over it would leave the reader believing the files went back.
  it("keeps the refusal on screen when putting files back would not run", async () => {
    vi.mocked(commands.projectChangesRestorePlan).mockResolvedValue({
      status: "ok",
      data: {
        kind: "effect",
        effect: {
          restored: [FILES[0]],
          removed: [],
          dropped: [],
          added: [],
          rerendered: [],
        },
      },
    });
    vi.mocked(commands.projectChangesRestore).mockResolvedValue({
      status: "ok",
      data: {
        kind: "refused",
        refused: {
          step: "the restore",
          said: ["error: unable to unlink"],
          timedOut: false,
          seconds: 30,
          gh: false,
        },
        done: {
          restored: [],
          removed: [],
          dropped: [],
          added: [],
          rerendered: [],
        },
      },
    });
    mount(<ProjectChangesPage />);
    await settle();
    await userEvent.click(button(REVERT_LABEL));
    await settle();
    await userEvent.click(button(REVERT_CONFIRM_LABEL));
    await settle();
    expect(body()).toContain("error: unable to unlink");
  });
});

// A restore writes in two passes, and a failure in the second leaves the
// first standing. Reporting that as a bare refusal tells a reader nothing
// happened while their files have already moved.
describe("a restore that stopped part-way", () => {
  const stopped = {
    status: "ok" as const,
    data: {
      kind: "refused" as const,
      refused: {
        step: "the restore",
        said: ["error: unable to unlink"],
        timedOut: false,
        seconds: 30,
        gh: false,
      },
      done: {
        restored: [FILES[0]],
        removed: [],
        dropped: [],
        added: [],
        rerendered: [],
      },
    },
  };

  beforeEach(() => {
    vi.mocked(commands.projectChangesRestorePlan).mockResolvedValue({
      status: "ok",
      data: {
        kind: "effect",
        effect: {
          restored: [FILES[0]],
          removed: [FILES[1]],
          dropped: [],
          added: [],
          rerendered: [],
        },
      },
    });
    vi.mocked(commands.projectChangesRestore).mockResolvedValue(stopped);
    // The re-read is the real one, so the project has to be tracked and the
    // whole-machine reads have to answer.
    useSettingsStore.setState({ settings: { projects: [ROOT] } as never });
    for (const read of [
      commands.scanMachine,
      commands.auditAll,
      commands.libraryProvenance,
    ] as const) {
      vi.mocked(read).mockResolvedValue({ status: "ok", data: [] as never });
    }
  });

  it("says what already went back, above git's words", async () => {
    mount(<ProjectChangesPage />);
    await settle();
    await userEvent.click(button(REVERT_LABEL));
    await settle();
    await userEvent.click(button(REVERT_CONFIRM_LABEL));
    await settle();
    expect(body()).toContain(PARTIAL_NOTE);
    expect(body()).toContain(FILES[0]);
    expect(body()).toContain("error: unable to unlink");
    // Never worded as a success, and the toast that would say so is not sent.
    expect(vi.mocked(toast.success)).not.toHaveBeenCalled();
  });

  // The page draws a set the run has already changed, so it is read again
  // even though nothing succeeded.
  it("reads the project again even though nothing succeeded", async () => {
    mount(<ProjectChangesPage />);
    await settle();
    await userEvent.click(button(REVERT_LABEL));
    await settle();
    await userEvent.click(button(REVERT_CONFIRM_LABEL));
    await settle();
    expect(commands.projectChangesScan).toHaveBeenCalled();
  });

  // A run that wrote nothing before it stopped has nothing to account for,
  // and claiming otherwise would be an empty list under a heading.
  it("accounts for nothing where the run wrote nothing", async () => {
    vi.mocked(commands.projectChangesRestore).mockResolvedValue({
      ...stopped,
      data: {
        ...stopped.data,
        done: {
          restored: [],
          removed: [],
          dropped: [],
          added: [],
          rerendered: [],
        },
      },
    });
    mount(<ProjectChangesPage />);
    await settle();
    await userEvent.click(button(REVERT_LABEL));
    await settle();
    await userEvent.click(button(REVERT_CONFIRM_LABEL));
    await settle();
    expect(body()).not.toContain(PARTIAL_NOTE);
    expect(body()).toContain("error: unable to unlink");
  });
});

// A restore moves the working tree; it does not change what kendex renders.
// A removal the next write undoes is not the effect the other groups
// describe, so the preview names it before the reader confirms.
describe("a restore the next write would undo", () => {
  it("names what kendex will write again", async () => {
    vi.mocked(commands.projectChangesRestorePlan).mockResolvedValue({
      status: "ok",
      data: {
        kind: "effect",
        effect: {
          restored: [],
          removed: [FILES[0]],
          dropped: [],
          added: [],
          rerendered: [FILES[0]],
        },
      },
    });
    mount(<ProjectChangesPage />);
    await settle();
    await userEvent.click(button(REVERT_LABEL));
    await settle();
    expect(body()).toContain(RERENDERED_LABEL);
    expect(body()).toContain(RERENDERED_NOTE);
  });
});
