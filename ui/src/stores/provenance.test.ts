import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type ItemKind, type ProvenanceRow } from "@/bindings";
import { READ_PENDING } from "@/lib/read-state";
import { NO_REASON_GIVEN } from "@/lib/settled";
import { useScanStore } from "@/stores/scan";
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
    at: null,
    origin: { origin: "marketplace", source: "kendex", repo: "acme/kendex" },
    package: { kind: "skill", name: "gh" },
  },
  {
    scope: { scope: "project", root: "/work/app" },
    kind: "skill",
    name: "gh",
    harness: "claude",
    at: null,
    origin: { origin: "own", forkedFrom: "kendex", source: "local" },
    package: { kind: "skill", name: "gh" },
  },
  {
    scope: { scope: "global" },
    kind: "agent",
    name: "gh",
    harness: "claude",
    at: null,
    origin: { origin: "unmanaged" },
    package: null,
  },
];

const recorded = (kind: ItemKind) =>
  ({ kind, name: "gh", identity: "recorded" }) as const;

describe("the From column's join", () => {
  it("matches the origin by kind, name and scope", () => {
    const rows = [
      {
        name: "global marketplace",
        kind: "skill" as const,
        scopes: [{ scope: "global" as const }],
        expected: {
          origin: "marketplace",
          source: "kendex",
          repo: "acme/kendex",
        },
      },
      {
        name: "project fork",
        kind: "skill" as const,
        scopes: [{ scope: "project" as const, root: "/work/app" }],
        expected: { origin: "own", forkedFrom: "kendex", source: "local" },
      },
      {
        name: "another kind",
        kind: "hook" as const,
        scopes: [{ scope: "global" as const }],
        expected: null,
      },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows)
      expect(originFor(ROWS, recorded(row.kind), row.scopes), row.name).toEqual(
        row.expected,
      );
  });

  // Two things can wear one kind, name and place: a package the records
  // account for and a file nothing recorded. Matched on the name alone the
  // unmanaged one reads as the marketplace package, and the package reads
  // as Not managed.
  it("keeps a package and a same-named file nobody installed apart", () => {
    const here = { scope: "project" as const, root: "/p" };
    const both: ProvenanceRow[] = [
      {
        scope: here,
        kind: "skill",
        name: "gh",
        harness: "claude",
        at: "/p/.claude/skills/gh",
        origin: { origin: "marketplace", source: "kendex", repo: "a/k" },
        package: { kind: "skill", name: "gh" },
      },
      {
        scope: here,
        kind: "skill",
        name: "gh",
        harness: "cursor",
        at: "/p/.cursor/skills/gh",
        origin: { origin: "unmanaged" },
        package: null,
      },
    ];
    expect(originFor(both, recorded("skill"), [here])).toEqual({
      origin: "marketplace",
      source: "kendex",
      repo: "a/k",
    });
    expect(
      originFor(
        both,
        {
          kind: "skill",
          name: "gh",
          identity: "observed",
          at: "/p/.cursor/skills/gh",
        },
        [here],
      ),
    ).toEqual({ origin: "unmanaged" });
  });

  it("carries the source, category and hover detail for each origin", () => {
    const marketplace = {
      origin: "marketplace" as const,
      source: "kendex",
      repo: "r",
    };
    const own = {
      origin: "own" as const,
      forkedFrom: "kendex",
      source: "local",
    };
    const rows: {
      name: string;
      read: typeof originTitle;
      origin: Parameters<typeof originLabel>[0];
      expected: string | undefined;
    }[] = [
      {
        name: "marketplace label",
        read: originLabel,
        origin: marketplace,
        expected: "kendex",
      },
      {
        name: "marketplace title",
        read: originTitle,
        origin: marketplace,
        expected: "r",
      },
      {
        name: "own label",
        read: originLabel,
        origin: own,
        expected: "Your own",
      },
      {
        name: "fork title",
        read: originTitle,
        origin: own,
        expected: "forked from kendex",
      },
      {
        name: "own without fork",
        read: originTitle,
        origin: { ...own, forkedFrom: null },
        expected: undefined,
      },
      {
        name: "unmanaged",
        read: originLabel,
        origin: { origin: "unmanaged" },
        expected: "Not managed",
      },
      { name: "unknown", read: originLabel, origin: null, expected: "" },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows)
      expect(row.read(row.origin), row.name).toBe(row.expected);
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

  // The two failure shapes. A refusal after a read that
  // landed takes the join back off current: the rows it leaves are the
  // older read's, and the gate closes on `read` alone. A refusal naming no
  // reason is still a failure with something to say, which is what `settled`
  // is here for, since the wrapper answers rather than throws.
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

// `ensureFor` is asked to make the join answer for one scan. Whether a read
// is running says nothing about which machine it will describe: one that
// began before this scan landed answers about the scan before it, and no
// state change asks again — the identity index and every count under it
// then stay unavailable until something else scans.
describe("the join asked to answer for one scan", () => {
  beforeEach(() => {
    useProvenanceStore.setState({
      rows: [],
      loaded: false,
      answeredFor: null,
      read: READ_PENDING,
      reading: false,
    });
    vi.clearAllMocks();
  });

  it("takes a re-read when the read out began before that scan", async () => {
    const running = park();
    vi.mocked(commands.libraryProvenance)
      .mockReturnValueOnce(running.promise)
      .mockResolvedValue({ status: "ok", data: AFTER });

    useScanStore.setState({ generation: 1 });
    const out = store().reload();
    // The scan lands while that read is still out.
    useScanStore.setState({ generation: 2 });
    const asked = store().ensureFor(2);

    running.land({ status: "ok", data: BEFORE });
    await out;
    await asked;

    expect(store().answeredFor).toBe(2);
    expect(commands.libraryProvenance).toHaveBeenCalledTimes(2);
  });

  // The inverse: a read that began after this scan is already its answer,
  // so asking again costs a second whole-machine read for nothing.
  it("adds no read when the one out already began after that scan", async () => {
    const running = park();
    vi.mocked(commands.libraryProvenance).mockReturnValueOnce(running.promise);

    useScanStore.setState({ generation: 3 });
    const out = store().reload();
    const asked = store().ensureFor(3);

    running.land({ status: "ok", data: AFTER });
    await out;
    await asked;

    expect(store().answeredFor).toBe(3);
    expect(commands.libraryProvenance).toHaveBeenCalledTimes(1);
  });
});
