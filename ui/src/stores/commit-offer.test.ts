import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type ProjectOffer } from "@/bindings";
import { routesFor, useCommitOfferStore } from "./commit-offer";

vi.mock("@/bindings", () => ({ commands: { commitOfferScan: vi.fn() } }));
vi.mock("sonner", () => ({ toast: { info: vi.fn(), success: vi.fn() } }));

/** A project with every choice standing: a remote chosen, `gh` answering,
 *  and no pull request open for the branch. */
const offer = (over: Partial<ProjectOffer> = {}): ProjectOffer => ({
  root: "/home/method/dev/site",
  name: "site",
  files: [".claude/CLAUDE.md", ".kendex-generated.json"],
  shared: [],
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
      flagged: [],
      stage: { at: "offer" },
      route: "commit",
      message: "",
      scanFailure: null,
    });
  });

  it("asks each project once, whatever the write reached it twice", async () => {
    vi.mocked(commands.commitOfferScan).mockResolvedValue({
      status: "ok",
      data: { offers: [offer()], flagged: [] },
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
      data: { offers: [offer({ files: ["one.md"] })], flagged: [] },
    });
    const { enqueue } = useCommitOfferStore.getState();
    await enqueue(["/home/method/dev/site"]);

    vi.mocked(commands.commitOfferScan).mockResolvedValueOnce({
      status: "ok",
      data: {
        offers: [offer({ files: ["one.md", "two.md"] })],
        flagged: [],
      },
    });
    await enqueue(["/home/method/dev/site"]);

    const state = useCommitOfferStore.getState();
    expect(state.queue.map((each) => each.root)).toEqual([
      "/home/method/dev/site",
    ]);
    expect(state.queue[0].files).toEqual(["one.md", "two.md"]);
  });

  // Except while it is being answered: that answer is in flight against
  // the offer on screen, and swapping it underneath would change what the
  // running step is about. The next scan corrects it.
  it("leaves the head alone while its answer is running", async () => {
    vi.mocked(commands.commitOfferScan).mockResolvedValueOnce({
      status: "ok",
      data: { offers: [offer({ files: ["one.md"] })], flagged: [] },
    });
    await useCommitOfferStore.getState().enqueue(["/home/method/dev/site"]);
    useCommitOfferStore.setState({ stage: { at: "busy", step: "commit" } });

    vi.mocked(commands.commitOfferScan).mockResolvedValueOnce({
      status: "ok",
      data: {
        offers: [offer({ files: ["one.md", "two.md"] })],
        flagged: [],
      },
    });
    await useCommitOfferStore.getState().enqueue(["/home/method/dev/site"]);

    expect(useCommitOfferStore.getState().queue[0].files).toEqual(["one.md"]);
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
        data: { offers: [offer({ files: ["two.md"] })], flagged: [] },
      });
    const outstanding = useCommitOfferStore
      .getState()
      .enqueue(["/home/method/dev/site"]);
    await useCommitOfferStore.getState().enqueue(["/home/method/dev/site"]);
    expect(useCommitOfferStore.getState().queue[0].files).toEqual(["two.md"]);
    return { outstanding, answer };
  };

  it("drops the stale reading an older scan answers with", async () => {
    const { outstanding, answer } = await olderScanOutstanding();
    answer({
      status: "ok",
      data: { offers: [offer({ files: ["one.md"] })], flagged: [] },
    });
    await outstanding;
    expect(useCommitOfferStore.getState().queue[0].files).toEqual(["two.md"]);
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
      data: { offers: [offer()], flagged: [] },
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
      data: { offers: [offer(), second], flagged: [] },
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
