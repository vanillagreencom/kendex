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

  // A read already out saw the machine as it was when it began, which is
  // not what a write behind it needs read. So a request arriving under one
  // takes a re-read behind it — however many arrive, one waits.
  it("takes one re-read behind the read already out, and keeps its answer", async () => {
    const running = park();
    vi.mocked(commands.libraryProvenance)
      .mockReturnValueOnce(running.promise)
      .mockResolvedValue({ status: "ok", data: AFTER });

    const out = store().reload();
    const behind = [store().reload(), store().reload()];

    running.land({ status: "ok", data: BEFORE });
    await out;
    await Promise.all(behind);

    expect(commands.libraryProvenance).toHaveBeenCalledTimes(2);
    expect(store().rows).toEqual(AFTER);
    expect(joinCurrent(store())).toBe(true);
  });

  // The re-read is about to replace these rows, so the surfaces gating on
  // the join stay shut across the gap between the two reads.
  it("holds the join uncurrent while a re-read is still to come", async () => {
    const running = park();
    const behind = park();
    vi.mocked(commands.libraryProvenance)
      .mockReturnValueOnce(running.promise)
      .mockReturnValueOnce(behind.promise);

    const out = store().reload();
    const queued = store().reload();

    running.land({ status: "ok", data: BEFORE });
    await out;
    expect(joinCurrent(store())).toBe(false);

    behind.land({ status: "ok", data: AFTER });
    await queued;
    expect(joinCurrent(store())).toBe(true);
    expect(store().rows).toEqual(AFTER);
  });

  // A read that failed keeps the rows it had and says why. The failure,
  // not a read still on its way, is what holds the gate shut.
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

  // A rejection is the same failed read as a returned refusal, and must
  // not leave the gate open or the join reading forever.
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
