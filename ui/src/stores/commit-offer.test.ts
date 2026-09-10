import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { type ChangedFile, commands, type ProjectOffer } from "@/bindings";
import { droppedToast, NOTHING_TO_COMMIT_TOAST } from "@/lib/copy-commit-offer";
import {
  ready,
  routesFor,
  selectionOf,
  useCommitOfferStore,
} from "./commit-offer";
import { useProjectChangesStore } from "./project-changes";

vi.mock("@/bindings", () => ({
  commands: {
    commitOfferScan: vi.fn(),
    commitOfferBaseline: vi.fn(),
    commitOfferCommit: vi.fn(),
    commitOfferPreviousHead: vi.fn(),
    commitOfferOpen: vi.fn(),
    projectChangesScan: vi.fn(),
  },
}));
vi.mock("sonner", () => ({ toast: { info: vi.fn(), success: vi.fn() } }));

/** One changed path the write is said to have made, unless the row says
 *  otherwise. */
const file = (path: string, over: Partial<ChangedFile> = {}): ChangedFile => ({
  path,
  did: "action",
  added: false,
  removed: false,
  ...over,
});

const named = (paths: string[]): ChangedFile[] => paths.map((p) => file(p));

/** A project with every choice standing: a remote chosen, `gh` answering,
 *  and no pull request open for the branch. */
const offer = (over: Partial<ProjectOffer> = {}): ProjectOffer => ({
  root: "/home/method/dev/site",
  name: "site",
  files: named([".claude/CLAUDE.md", ".kendex-generated.json"]),
  actionPaths: [".claude/CLAUDE.md", ".kendex-generated.json"],
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
  ...over,
});

// The rows of the design's state table that decide which segments the
// offer draws, `docs/design/post-refresh-commit-flow.md` § State table.
describe("the choices an offer carries", () => {
  it("offers the routes allowed by each offer", () => {
    const rows: { name: string; offer: ProjectOffer; routes: string[] }[] = [
      { name: "all routes", offer: offer(), routes: ["commit", "push", "pr"] },
      {
        name: "no remote",
        offer: offer({
          remote: null,
          repo: null,
          push: { kind: "noRemote" },
          pullRequest: { kind: "noRemote" },
        }),
        routes: ["commit"],
      },
      {
        name: "gh missing",
        offer: offer({ repo: null, pullRequest: { kind: "ghMissing" } }),
        routes: ["commit", "push"],
      },
      {
        name: "pull request open",
        offer: offer({ openNumber: 41 }),
        routes: ["commit", "push"],
      },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows)
      expect(routesFor(row.offer), row.name).toEqual(row.routes);
  });
});

// kendex asks at most once per run per project: a project already in the
// line keeps its place, and leaving takes it off the line.
describe("the line of projects to ask", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useCommitOfferStore.setState({
      queue: [],
      stage: { at: "offer" },
      route: "commit",
      scoped: "action",
      accepted: false,
      message: "",
      scanFailure: null,
      baselines: {},
    });
    vi.mocked(commands.commitOfferBaseline).mockResolvedValue({
      status: "ok",
      data: [],
    });
  });

  it("asks each project once, whatever the write reached it twice", async () => {
    vi.mocked(commands.commitOfferScan).mockResolvedValue({
      status: "ok",
      data: [offer()],
    });
    const { enqueue } = useCommitOfferStore.getState();
    await enqueue(["/home/method/dev/site"]);
    await enqueue(["/home/method/dev/site"]);
    const state = useCommitOfferStore.getState();
    expect(state.queue.map((each) => each.root)).toEqual([
      "/home/method/dev/site",
    ]);
    expect(state.message).toBe("chore: kendex refresh");
    expect(commands.commitOfferScan).toHaveBeenCalledTimes(2);
  });

  // A project's place in the line is kept; its READING is not. The guided
  // install writes per place and per marketplace, each through its own
  // `writingRepo`, so a second write can land while the first project's
  // offer is already queued — and the commit re-derives the generated
  // paths when it runs. Keeping the first reading is what lets a commit
  // take files the dialog never listed.
  it("takes the fresh reading for a project already in the line", async () => {
    vi.mocked(commands.commitOfferScan).mockResolvedValueOnce({
      status: "ok",
      data: [offer({ files: named(["one.md"]) })],
    });
    const { enqueue } = useCommitOfferStore.getState();
    await enqueue(["/home/method/dev/site"]);

    vi.mocked(commands.commitOfferScan).mockResolvedValueOnce({
      status: "ok",
      data: [offer({ files: named(["one.md", "two.md"]) })],
    });
    await enqueue(["/home/method/dev/site"]);

    const state = useCommitOfferStore.getState();
    expect(state.queue.map((each) => each.root)).toEqual([
      "/home/method/dev/site",
    ]);
    expect(state.queue[0].files.map((each) => each.path)).toEqual([
      "one.md",
      "two.md",
    ]);
  });

  // Except while it is being answered: that answer is in flight against
  // the offer on screen, and swapping it underneath would change what the
  // running step is about. The next scan corrects it.
  it("leaves the head alone while its answer is running", async () => {
    vi.mocked(commands.commitOfferScan).mockResolvedValueOnce({
      status: "ok",
      data: [offer({ files: named(["one.md"]) })],
    });
    await useCommitOfferStore.getState().enqueue(["/home/method/dev/site"]);
    useCommitOfferStore.setState({ stage: { at: "busy", step: "commit" } });

    vi.mocked(commands.commitOfferScan).mockResolvedValueOnce({
      status: "ok",
      data: [offer({ files: named(["one.md", "two.md"]) })],
    });
    await useCommitOfferStore.getState().enqueue(["/home/method/dev/site"]);

    expect(
      useCommitOfferStore.getState().queue[0].files.map((each) => each.path),
    ).toEqual(["one.md"]);
  });

  // The scans overlap and can answer in any order: `writingRepo` starts one
  // per write without waiting on it, and one reader action writes many
  // times. An older answer read the projects before the newer one's write,
  // so it is dropped whole — the reading a commit would take files
  // against, and the failure that is no account of a read landing after it.
  //
  // `outstanding` is the older scan, held until the newer one has answered.
  type Answer = Awaited<ReturnType<typeof commands.commitOfferScan>>;
  const olderScanOutstanding = async () => {
    let answer = (_: Answer) => {};
    const older = new Promise<Answer>((resolve) => {
      answer = resolve;
    });
    vi.mocked(commands.commitOfferScan)
      .mockReturnValueOnce(older)
      .mockResolvedValueOnce({
        status: "ok",
        data: [offer({ files: named(["two.md"]) })],
      });
    const outstanding = useCommitOfferStore
      .getState()
      .enqueue(["/home/method/dev/site"]);
    await useCommitOfferStore.getState().enqueue(["/home/method/dev/site"]);
    expect(
      useCommitOfferStore.getState().queue[0].files.map((each) => each.path),
    ).toEqual(["two.md"]);
    return { outstanding, answer };
  };

  it("drops the stale reading an older scan answers with", async () => {
    const { outstanding, answer } = await olderScanOutstanding();
    answer({
      status: "ok",
      data: [offer({ files: named(["one.md"]) })],
    });
    await outstanding;
    expect(
      useCommitOfferStore.getState().queue[0].files.map((each) => each.path),
    ).toEqual(["two.md"]);
  });

  it("drops the failure an older scan answers with", async () => {
    const { outstanding, answer } = await olderScanOutstanding();
    answer({ status: "error", error: "git is not on the path" });
    await outstanding;
    expect(useCommitOfferStore.getState().scanFailure).toBeNull();
  });

  // A failure is what one read of these projects answered, and a later read
  // of the same projects answered them. Held past that, it would be said
  // over a reading that had already replaced it.
  it("clears a held failure once a later scan reads the projects", async () => {
    vi.mocked(commands.commitOfferScan).mockResolvedValueOnce({
      status: "error",
      error: "git is not on the path",
    });
    await useCommitOfferStore.getState().enqueue(["/home/method/dev/site"]);
    expect(useCommitOfferStore.getState().scanFailure).toBe(
      "git is not on the path",
    );

    vi.mocked(commands.commitOfferScan).mockResolvedValueOnce({
      status: "ok",
      data: [offer()],
    });
    await useCommitOfferStore.getState().enqueue(["/home/method/dev/site"]);
    expect(useCommitOfferStore.getState().scanFailure).toBeNull();
  });

  it("asks nothing when the write could reach no project", async () => {
    await useCommitOfferStore.getState().enqueue([]);
    expect(commands.commitOfferScan).not.toHaveBeenCalled();
  });

  it("leaves the files as diffs and moves to the next project", async () => {
    const second = offer({ root: "/home/method/dev/other", name: "other" });
    vi.mocked(commands.commitOfferScan).mockResolvedValue({
      status: "ok",
      data: [offer(), second],
    });
    await useCommitOfferStore.getState().enqueue(["/a", "/b"]);
    useCommitOfferStore.getState().pick("pr");
    useCommitOfferStore.getState().leave();
    const state = useCommitOfferStore.getState();
    expect(state.queue.map((each) => each.root)).toEqual([
      "/home/method/dev/other",
    ]);
    expect(state.stage).toEqual({ at: "offer" });
    expect(state.route).toBe("commit");
    useCommitOfferStore.getState().leave();
    expect(useCommitOfferStore.getState().queue).toEqual([]);
  });
});

// The reading the offer is scoped against. One reader action runs many
// writes — the guided install writes once per place and once per
// marketplace inside each — so the reading has to be the one taken before
// the FIRST of them, or the install's own earlier steps read as work that
// was already there.
describe("the reading an action is scoped against", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useCommitOfferStore.setState({
      queue: [],
      stage: { at: "offer" },
      route: "commit",
      scoped: "action",
      accepted: false,
      message: "",
      scanFailure: null,
      baselines: {},
    });
    vi.mocked(commands.commitOfferBaseline).mockResolvedValue({
      status: "ok",
      data: [{ root: "/home/method/dev/site", held: [] }],
    });
    vi.mocked(commands.commitOfferScan).mockResolvedValue({
      status: "ok",
      data: [offer()],
    });
  });

  it("keeps the first reading through a burst of writes", async () => {
    const { noteBaseline } = useCommitOfferStore.getState();
    await noteBaseline(["/home/method/dev/site"]);
    await noteBaseline(["/home/method/dev/site"]);
    expect(commands.commitOfferBaseline).toHaveBeenCalledTimes(1);
    await useCommitOfferStore.getState().enqueue(["/home/method/dev/site"]);
    expect(commands.commitOfferScan).toHaveBeenCalledWith(
      ["/home/method/dev/site"],
      [{ root: "/home/method/dev/site", held: [] }],
    );
  });

  // Answered means answered: the next write in this project reads it
  // afresh, so whatever the reader chose to leave behind is older work from
  // that write's point of view rather than part of it.
  it("reads the project again once its question is answered", async () => {
    const { noteBaseline } = useCommitOfferStore.getState();
    await noteBaseline(["/home/method/dev/site"]);
    await useCommitOfferStore.getState().enqueue(["/home/method/dev/site"]);
    useCommitOfferStore.getState().leave();
    await useCommitOfferStore
      .getState()
      .noteBaseline(["/home/method/dev/site"]);
    expect(commands.commitOfferBaseline).toHaveBeenCalledTimes(2);
  });

  // A reading is spent once the write it was taken for has been read for,
  // and a read that FAILED has still had its turn. Held past that, the next
  // write in the same project would be compared against a reading taken
  // before somebody else's action, and that action's files would be
  // reported as this write's own.
  it("keeps no reading past a scan that failed", async () => {
    vi.mocked(commands.commitOfferScan).mockResolvedValue({
      status: "error",
      error: "git is not on the path",
    });
    await useCommitOfferStore
      .getState()
      .noteBaseline(["/home/method/dev/site"]);
    await useCommitOfferStore.getState().enqueue(["/home/method/dev/site"]);
    expect(useCommitOfferStore.getState().scanFailure).toBe(
      "git is not on the path",
    );
    expect(useCommitOfferStore.getState().baselines).toEqual({});

    // So the next write reads the project again rather than comparing
    // against the reading that scan never got to use.
    await useCommitOfferStore
      .getState()
      .noteBaseline(["/home/method/dev/site"]);
    expect(commands.commitOfferBaseline).toHaveBeenCalledTimes(2);
  });

  // A reading that would not run records nothing, and the offer after the
  // write then attributes every pending change to that write. Over-reporting
  // rather than labelling somebody else's work as this action's.
  it("records nothing from a reading that would not run", async () => {
    vi.mocked(commands.commitOfferBaseline).mockResolvedValue({
      status: "error",
      error: "git is not on the path",
    });
    await useCommitOfferStore
      .getState()
      .noteBaseline(["/home/method/dev/site"]);
    await useCommitOfferStore.getState().enqueue(["/home/method/dev/site"]);
    expect(commands.commitOfferScan).toHaveBeenCalledWith(
      ["/home/method/dev/site"],
      [],
    );
  });
});

// Which pending changes a step carries, and when the reader has to say so.
// The rule: a commit labelled as one action's work never carries an earlier
// change nobody said yes to.
describe("the set a step carries", () => {
  const state = (over: Partial<Parameters<typeof selectionOf>[0]> = {}) => ({
    queue: [offer({ choice: true, actionPaths: ["one.md"] })],
    scoped: "action" as const,
    ...over,
  });

  it("sends the action's own paths, or everything, as the reader picked", () => {
    expect(selectionOf(state())).toEqual({ kind: "only", paths: ["one.md"] });
    expect(selectionOf(state({ scoped: "all" }))).toEqual({ kind: "all" });
  });

  // A review a person opened themselves has no action to scope to, so
  // asking for one would send an empty list and commit nothing.
  it("sends everything where no action opened the offer", () => {
    expect(
      selectionOf({ queue: [offer({ actionPaths: [] })], scoped: "action" }),
    ).toEqual({ kind: "all" });
    expect(selectionOf({ queue: [], scoped: "action" })).toEqual({
      kind: "all",
    });
  });

  it("holds the action's own commit until the earlier changes are accepted", () => {
    const tangled = offer({
      choice: true,
      actionPaths: ["one.md"],
      tangled: [{ path: "one.md", reason: "carriesEarlier" }],
    });
    expect(ready({ queue: [tangled], scoped: "action", accepted: false })).toBe(
      false,
    );
    expect(ready({ queue: [tangled], scoped: "action", accepted: true })).toBe(
      true,
    );
    // Every other state runs: all-pending never claims to be one action's
    // work, and an offer with nothing tangled has nothing to accept.
    expect(ready({ queue: [tangled], scoped: "all", accepted: false })).toBe(
      true,
    );
    expect(ready({ queue: [offer()], scoped: "action", accepted: false })).toBe(
      true,
    );
  });

  // Picking a different set drops the acceptance with it: a yes given about
  // one set is not a yes about another.
  it("drops an acceptance when the set changes", () => {
    useCommitOfferStore.setState({ accepted: true });
    useCommitOfferStore.getState().scope("all");
    expect(useCommitOfferStore.getState().accepted).toBe(false);
  });
});

// What the commit actually carries, and what a dismissal is worth.
describe("answering an offer", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useCommitOfferStore.setState({
      queue: [],
      stage: { at: "offer" },
      route: "commit",
      scoped: "action",
      accepted: false,
      message: "",
      scanFailure: null,
      baselines: {},
    });
    vi.mocked(commands.commitOfferBaseline).mockResolvedValue({
      status: "ok",
      data: [],
    });
    vi.mocked(commands.commitOfferPreviousHead).mockResolvedValue({
      status: "ok",
      data: "abc1234",
    });
    vi.mocked(commands.commitOfferCommit).mockResolvedValue({
      status: "ok",
      data: { kind: "made", sha: "def5678", files: 1, dropped: [] },
    });
  });

  // Every path the reader picked changed back before the commit ran, so
  // there was nothing left to commit. The names travel with that answer:
  // "nothing to commit" on its own leaves them wondering what became of the
  // files they chose.
  it("names the picked files when none of them is left", async () => {
    vi.mocked(commands.commitOfferScan).mockResolvedValue({
      status: "ok",
      data: [offer({ choice: true, actionPaths: ["one.md"] })],
    });
    vi.mocked(commands.commitOfferCommit).mockResolvedValue({
      status: "ok",
      data: { kind: "nothing", dropped: ["one.md"] },
    });
    await useCommitOfferStore.getState().enqueue(["/home/method/dev/site"]);
    await useCommitOfferStore.getState().run();
    expect(toast.info).toHaveBeenCalledWith(droppedToast(["one.md"]));
    expect(toast.info).toHaveBeenCalledWith(NOTHING_TO_COMMIT_TOAST);
  });

  // The set the reader picked reaches the commit as the paths themselves.
  // A label alone would leave core re-deriving everything pending, which is
  // the whole of what "only this action" has to rule out.
  it("commits the paths the picked set names", async () => {
    vi.mocked(commands.commitOfferScan).mockResolvedValue({
      status: "ok",
      data: [offer({ choice: true, actionPaths: ["one.md"] })],
    });
    await useCommitOfferStore.getState().enqueue(["/home/method/dev/site"]);
    await useCommitOfferStore.getState().run();
    expect(commands.commitOfferCommit).toHaveBeenCalledWith(
      "/home/method/dev/site",
      "chore: kendex refresh",
      { kind: "only", paths: ["one.md"] },
    );

    useCommitOfferStore.setState({ scoped: "all" });
    await useCommitOfferStore.getState().enqueue(["/home/method/dev/site"]);
    await useCommitOfferStore.getState().run();
    expect(commands.commitOfferCommit).toHaveBeenLastCalledWith(
      "/home/method/dev/site",
      "chore: kendex refresh",
      { kind: "all" },
    );
  });

  // Dismissing is an answer, and it lasts. The passive read behind the
  // project cards never enqueues, so a refresh — start-up, focus, a scan —
  // cannot put a dismissed question back on screen.
  it("keeps a dismissal through a passive read of the same project", async () => {
    vi.mocked(commands.projectChangesScan).mockResolvedValue({
      status: "ok",
      data: [
        {
          root: "/home/method/dev/site",
          name: "site",
          state: {
            kind: "pending",
            files: [".claude/CLAUDE.md"],
            shared: [],
            others: 0,
            branch: "main",
            operation: null,
          },
        },
      ],
    });
    vi.mocked(commands.commitOfferScan).mockResolvedValue({
      status: "ok",
      data: [offer()],
    });
    await useCommitOfferStore.getState().enqueue(["/home/method/dev/site"]);
    useCommitOfferStore.getState().leave();
    expect(useCommitOfferStore.getState().queue).toEqual([]);

    await useProjectChangesStore.getState().refresh(["/home/method/dev/site"]);
    // The changes are still there to review, and the question stays shut.
    expect(useProjectChangesStore.getState().rows).toHaveLength(1);
    expect(useCommitOfferStore.getState().queue).toEqual([]);
  });

  // A write in another project says nothing about this one: the backend
  // reports an offer only where the write itself changed something, and the
  // line stays as it was.
  it("adds nothing for a write that changed nothing here", async () => {
    vi.mocked(commands.commitOfferScan).mockResolvedValue({
      status: "ok",
      data: [],
    });
    await useCommitOfferStore.getState().enqueue(["/home/method/dev/site"]);
    expect(useCommitOfferStore.getState().queue).toEqual([]);
  });
});

// An offer with no choice to make still asks for the yes. `choice` is false
// where the action's own work and everything pending are the same commit —
// which does not make the earlier changes in those files the reader's own,
// and the one commit on offer carries them. The dialog draws the answer in
// that branch too, so the gate is one a reader can free.
describe("an offer with no choice to make", () => {
  it("waits for the yes before committing earlier work", () => {
    const both = offer({
      choice: false,
      tangled: [{ path: "one.md", reason: "carriesEarlier" }],
    });
    expect(ready({ queue: [both], scoped: "action", accepted: false })).toBe(
      false,
    );
    expect(ready({ queue: [both], scoped: "action", accepted: true })).toBe(
      true,
    );
    // Picking every pending change is itself that answer: the reader asked
    // for the earlier work by name.
    const choosable = offer({
      choice: true,
      actionPaths: ["one.md"],
      tangled: [{ path: "one.md", reason: "carriesEarlier" }],
    });
    expect(
      ready({ queue: [choosable], scoped: "action", accepted: false }),
    ).toBe(false);
    expect(ready({ queue: [choosable], scoped: "all", accepted: false })).toBe(
      true,
    );
  });

  // With no choice on screen the two labels name the same commit, so the set
  // sent is the whole pending one either way.
  it("sends the same set whichever label is picked", () => {
    const both = offer({ choice: false });
    expect(selectionOf({ queue: [both], scoped: "all" })).toEqual({
      kind: "all",
    });
    expect(selectionOf({ queue: [both], scoped: "action" })).toEqual({
      kind: "only",
      paths: both.actionPaths,
    });
  });
});

// The root travels as a KEY, not as something to print. A backend that
// re-spelled it — slashes for the platform separator — would miss every
// lookup, and a missing baseline makes every pending path read as this
// action's, which is the outcome the issue forbids.
describe("the root a project is looked up by", () => {
  const WINDOWS = "C:\\Users\\me\\dev\\site";

  beforeEach(() => {
    vi.clearAllMocks();
    useCommitOfferStore.setState({
      queue: [],
      stage: { at: "offer" },
      route: "commit",
      scoped: "action",
      accepted: false,
      message: "",
      scanFailure: null,
      baselines: {},
    });
  });

  it("sends back the spelling it was given", async () => {
    vi.mocked(commands.commitOfferBaseline).mockResolvedValue({
      status: "ok",
      data: [{ root: WINDOWS, held: [] }],
    });
    vi.mocked(commands.commitOfferScan).mockResolvedValue({
      status: "ok",
      data: [offer({ root: WINDOWS })],
    });
    await useCommitOfferStore.getState().noteBaseline([WINDOWS]);
    await useCommitOfferStore.getState().enqueue([WINDOWS]);
    // The reading reached the scan, which is what makes attribution work.
    expect(commands.commitOfferScan).toHaveBeenCalledWith(
      [WINDOWS],
      [{ root: WINDOWS, held: [] }],
    );
    // And the queue is keyed by the same spelling, so leaving answers it.
    expect(useCommitOfferStore.getState().queue[0].root).toBe(WINDOWS);
    useCommitOfferStore.getState().leave();
    expect(useCommitOfferStore.getState().queue).toEqual([]);
  });

  // The must-fail direction of the same rule: a backend that answered under
  // a different spelling sends no reading, and the offer then attributes
  // every pending path to this action.
  it("sends no reading when the answer comes back re-spelled", async () => {
    vi.mocked(commands.commitOfferBaseline).mockResolvedValue({
      status: "ok",
      data: [{ root: "C:/Users/me/dev/site", held: [] }],
    });
    vi.mocked(commands.commitOfferScan).mockResolvedValue({
      status: "ok",
      data: [],
    });
    await useCommitOfferStore.getState().noteBaseline([WINDOWS]);
    await useCommitOfferStore.getState().enqueue([WINDOWS]);
    expect(commands.commitOfferScan).toHaveBeenCalledWith([WINDOWS], []);
  });
});

// A person opens a project's review while a scan an earlier write started
// is still out. That scan answers about the write, with its scope and its
// attribution; landing it over the offer they asked for answers a question
// nobody put.
describe("a review a person opened, against a scan already out", () => {
  beforeEach(() => {
    useCommitOfferStore.setState({
      queue: [],
      stage: { at: "offer" },
      route: "commit",
      scoped: "action",
      accepted: false,
      message: "",
      scanFailure: null,
      scanning: false,
      baselines: {},
      asked: null,
    });
  });

  it("keeps what the reader asked for when the late scan lands", async () => {
    const root = "/home/method/dev/site";
    let answer = (_: unknown): void => {};
    vi.mocked(commands.commitOfferScan).mockReturnValue(
      new Promise((resolve) => {
        answer = resolve;
      }) as never,
    );
    const out = useCommitOfferStore.getState().enqueue([root]);

    // Opened by the reader: nothing attributed, everything pending.
    vi.mocked(commands.commitOfferOpen).mockResolvedValue({
      status: "ok",
      data: {
        kind: "offer",
        offer: offer({ actionPaths: [], choice: false }),
      },
    });
    await useCommitOfferStore.getState().openFor(root);
    expect(useCommitOfferStore.getState().scoped).toBe("all");

    // The earlier write's scan answers now, attributing files to it.
    answer({
      status: "ok",
      data: [offer({ actionPaths: ["one.md"], choice: true })],
    });
    await out;

    const head = useCommitOfferStore.getState().queue[0];
    expect(head.actionPaths, "the write's scope replaced the reader's").toEqual(
      [],
    );
    expect(head.choice).toBe(false);
  });
});

// A scan behind a write reads several projects and answers later. In
// between, a project can stop being one: reconnected to another folder,
// or removed. The answer is about the folder it was started for, and
// putting it back reopens the very prompt the forget closed.
describe("a project that stops being one while a scan is out", () => {
  beforeEach(() => {
    useCommitOfferStore.setState({
      queue: [],
      stage: { at: "offer" },
      route: "commit",
      message: "",
      scanFailure: null,
      scanning: false,
      baselines: {},
    });
  });

  it("keeps a late answer about it out of the line", async () => {
    let answer = (_: unknown): void => {};
    vi.mocked(commands.commitOfferScan).mockReturnValue(
      new Promise((resolve) => {
        answer = resolve;
      }) as never,
    );
    const gone = offer({ root: "/work/vsys-view", name: "vsys-view" });

    const out = useCommitOfferStore.getState().enqueue([gone.root]);
    useCommitOfferStore.getState().forget(gone.root);
    answer({ status: "ok", data: [gone] });
    await out;

    expect(useCommitOfferStore.getState().queue).toEqual([]);
  });

  // The reading taken before the write goes with the folder: a question
  // about files at a path nothing points at any more is not one to keep.
  it("keeps no reading for a folder that stopped being a project", async () => {
    const gone = offer({ root: "/work/vsys-view", name: "vsys-view" });
    vi.mocked(commands.commitOfferBaseline).mockResolvedValue({
      status: "ok",
      data: [{ root: gone.root, held: [] }],
    });
    await useCommitOfferStore.getState().noteBaseline([gone.root]);
    expect(useCommitOfferStore.getState().baselines).toHaveProperty(gone.root);

    useCommitOfferStore.getState().forget(gone.root);
    expect(useCommitOfferStore.getState().baselines).toEqual({});
  });

  // The same folder registered afresh is a project again, and the ask
  // that names it is what says so.
  it("asks about it again once it is registered again", async () => {
    const back = offer({ root: "/work/vsys-view", name: "vsys-view" });
    useCommitOfferStore.getState().forget(back.root);
    vi.mocked(commands.commitOfferScan).mockResolvedValue({
      status: "ok",
      data: [back],
    });

    await useCommitOfferStore.getState().enqueue([back.root]);

    expect(useCommitOfferStore.getState().queue.map((one) => one.root)).toEqual(
      [back.root],
    );
  });
});
