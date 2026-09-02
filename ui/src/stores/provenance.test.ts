import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type ProvenanceRow } from "@/bindings";
import { READ_PENDING } from "@/lib/read-state";
import {
  joinCurrent,
  originFor,
  originLabel,
  originTitle,
  useProvenanceStore,
} from "./provenance";

vi.mock("@/bindings", () => ({
  commands: {
    libraryProvenance: vi.fn(),
  },
}));

const ROWS: ProvenanceRow[] = [
  {
    scope: { scope: "global" },
    kind: "skill",
    name: "gh",
    harness: "claude",
    origin: { origin: "marketplace", source: "kendex", repo: "acme/kendex" },
  },
  {
    scope: { scope: "project", root: "/work/app" },
    kind: "skill",
    name: "gh",
    harness: "claude",
    origin: { origin: "own", forkedFrom: "kendex", source: "local" },
  },
  {
    scope: { scope: "global" },
    kind: "agent",
    name: "gh",
    harness: "claude",
    origin: { origin: "unmanaged" },
  },
];

describe("the From column's join", () => {
  it("matches by kind, name, and any of the group's scopes", () => {
    const origin = originFor(ROWS, "skill", "gh", [{ scope: "global" }]);
    expect(origin).toEqual({
      origin: "marketplace",
      source: "kendex",
      repo: "acme/kendex",
    });
    // The same name in another scope answers with that scope's origin —
    // a fork there does not relabel the global install.
    expect(
      originFor(ROWS, "skill", "gh", [{ scope: "project", root: "/work/app" }]),
    ).toEqual({ origin: "own", forkedFrom: "kendex", source: "local" });
    // A same-named item of another kind never borrows this one's origin.
    expect(originFor(ROWS, "hook", "gh", [{ scope: "global" }])).toBeNull();
  });

  it("labels origins in product words with the detail on hover", () => {
    expect(
      originLabel({ origin: "marketplace", source: "kendex", repo: "r" }),
    ).toBe("kendex");
    expect(
      originTitle({ origin: "marketplace", source: "kendex", repo: "r" }),
    ).toBe("r");
    expect(
      originLabel({ origin: "own", forkedFrom: "kendex", source: "local" }),
    ).toBe("Your own");
    expect(
      originTitle({ origin: "own", forkedFrom: "kendex", source: "local" }),
    ).toBe("forked from kendex");
    expect(
      originTitle({ origin: "own", forkedFrom: null, source: "local" }),
    ).toBeUndefined();
    expect(originLabel({ origin: "unmanaged" })).toBe("Not managed");
    expect(originLabel(null)).toBe("");
  });
});

/** A join read this test answers by hand, to hold one open. */
const park = () => {
  let land: (value: JoinAnswer) => void = () => {};
  const promise = new Promise<JoinAnswer>((resolve) => {
    land = resolve;
  });
  return { promise, land };
};

type JoinAnswer = Awaited<ReturnType<typeof commands.libraryProvenance>>;

/** What the join said before an install landed, and after it. */
const BEFORE: ProvenanceRow[] = [ROWS[0]];
const AFTER: ProvenanceRow[] = ROWS;

const store = () => useProvenanceStore.getState();

describe("overlapping reads of the join", () => {
  beforeEach(() => {
    useProvenanceStore.setState({
      rows: [],
      loaded: false,
      read: READ_PENDING,
      reading: false,
    });
    vi.clearAllMocks();
  });

  // The Scan again press and the read behind a write are routinely out at
  // once, and the press's read began first — so it saw the older machine
  // however late it answers, and answering late must not put that machine
  // back on the page.
  it("keeps the newer answer when the read that began first lands last", async () => {
    const slow = park();
    vi.mocked(commands.libraryProvenance)
      .mockReturnValueOnce(slow.promise)
      .mockResolvedValueOnce({ status: "ok", data: AFTER });

    const older = store().reload();
    await store().reload();
    expect(store().rows).toEqual(AFTER);

    slow.land({ status: "ok", data: BEFORE });
    await older;

    expect(store().rows).toEqual(AFTER);
    expect(store().read.status).toBe("landed");
  });

  // The rows are not current while a read that supersedes them is still
  // coming, and the two gating surfaces read that off the store rather than
  // off their own call — so the landing that makes them current re-renders
  // them.
  it("holds the join uncurrent until the newest read lands", async () => {
    const slow = park();
    const newer = park();
    vi.mocked(commands.libraryProvenance)
      .mockReturnValueOnce(slow.promise)
      .mockReturnValueOnce(newer.promise);

    const older = store().reload();
    const outstanding = store().reload();

    slow.land({ status: "ok", data: BEFORE });
    await older;
    expect(joinCurrent(store())).toBe(false);
    expect(store().rows).toEqual([]);

    newer.land({ status: "ok", data: AFTER });
    await outstanding;
    expect(joinCurrent(store())).toBe(true);
    expect(store().rows).toEqual(AFTER);
  });

  // A read that failed keeps the rows it had and says why. It spends its
  // ticket like any other answer, so nothing is left looking outstanding —
  // the failure, not a read still on its way, is what holds the gate shut.
  it("keeps the rows a failed read could not replace, and says why", async () => {
    vi.mocked(commands.libraryProvenance)
      .mockResolvedValueOnce({ status: "ok", data: AFTER })
      .mockResolvedValueOnce({
        status: "error",
        error: "the join did not read",
      });

    await store().reload();
    await store().reload();

    expect(store().rows).toEqual(AFTER);
    expect(store().reading).toBe(false);
    expect(store().read).toEqual({
      status: "failed",
      error: "the join did not read",
    });
    expect(joinCurrent(store())).toBe(false);
  });

  // Nothing awaits the read behind a write, so a call that throws where a
  // promise was expected — a page with no Tauri behind the wrapper — would
  // be an unhandled rejection at the window rather than a read that failed.
  it("lands a call that throws outright as a failed read", async () => {
    vi.mocked(commands.libraryProvenance).mockImplementationOnce(() => {
      throw new Error("nothing behind the call");
    });

    await expect(store().reload()).resolves.toBeUndefined();

    expect(store().read).toEqual({
      status: "failed",
      error: "nothing behind the call",
    });
    expect(store().reading).toBe(false);
  });

  // A rejection is the same failed read as a returned refusal: the
  // generated wrapper rethrows a transport failure, and a read that never
  // answered must not leave the gate open or the join reading forever.
  it("lands a rejected call as a failed read", async () => {
    vi.mocked(commands.libraryProvenance).mockRejectedValueOnce(
      new Error("the channel is gone"),
    );

    await store().reload();

    expect(store().read).toEqual({
      status: "failed",
      error: "the channel is gone",
    });
    expect(store().reading).toBe(false);
  });
});
