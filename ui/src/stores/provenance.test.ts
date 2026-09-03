import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type ProvenanceRow } from "@/bindings";
import { READ_PENDING } from "@/lib/read-state";
import { NO_REASON_GIVEN } from "@/lib/settled";
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

  // A read hands `inFlight` back before the re-read behind it starts, so
  // there is a moment with nothing running and one still scheduled. A
  // request arriving there joins what is scheduled: its own read would put
  // two out at once, and nothing ranks them.
  it("joins the re-read already scheduled rather than starting a second", async () => {
    const running = park();
    vi.mocked(commands.libraryProvenance)
      .mockReturnValueOnce(running.promise)
      .mockResolvedValue({ status: "ok", data: AFTER });

    const out = store().reload();
    // Registered before the request that queues the re-read, so it runs in
    // the gap rather than behind the re-read's own start.
    const inTheGap = out.then(() => store().reload());
    const behind = store().reload();

    running.land({ status: "ok", data: BEFORE });
    await Promise.all([out, behind, inTheGap]);

    expect(commands.libraryProvenance).toHaveBeenCalledTimes(2);
    expect(store().rows).toEqual(AFTER);
  });

  // What a surface reads is what the store PUBLISHES, not what it holds
  // once everything has settled. Between the running read landing and the
  // re-read starting, the rows are a landed answer a scheduled read is
  // about to replace, so `joinCurrent` must not go true there — which only
  // a subscription across the sequence can see.
  it("never publishes the join as current before the last read lands", async () => {
    const running = park();
    const behind = park();
    vi.mocked(commands.libraryProvenance)
      .mockReturnValueOnce(running.promise)
      .mockReturnValueOnce(behind.promise);

    const published: boolean[] = [];
    const stop = useProvenanceStore.subscribe((state) =>
      published.push(joinCurrent(state)),
    );

    const out = store().reload();
    const queued = store().reload();
    running.land({ status: "ok", data: BEFORE });
    await out;
    behind.land({ status: "ok", data: AFTER });
    await queued;
    stop();

    expect(published.slice(0, -1)).not.toContain(true);
    expect(published.at(-1)).toBe(true);
  });

  // The two failures a shipped path still produces. A refusal after a read
  // that landed takes the join back off current: the rows it leaves are the
  // older read's, and the gate closes on `read` alone. A refusal naming no
  // reason is still a failure with something to say, which is what `settled`
  // is here for now that the wrapper answers rather than throws.
  it("lands an engine refusal as a failed read, empty reason and all", async () => {
    vi.mocked(commands.libraryProvenance)
      .mockResolvedValueOnce({ status: "ok", data: AFTER })
      .mockResolvedValueOnce({
        status: "error",
        error: "the join did not read",
      });

    await store().reload();
    await store().reload();

    expect(store().rows).toEqual(AFTER);
    expect(store().read).toEqual({
      status: "failed",
      error: "the join did not read",
    });
    expect(joinCurrent(store())).toBe(false);
    expect(store().reading).toBe(false);

    vi.mocked(commands.libraryProvenance).mockResolvedValueOnce({
      status: "error",
      error: "",
    });
    await store().reload();

    expect(store().read).toEqual({ status: "failed", error: NO_REASON_GIVEN });
  });
});
