import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type ProvenanceRow } from "@/bindings";
import {
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

describe("overlapping reads of the join", () => {
  beforeEach(() => {
    useProvenanceStore.setState({ rows: [], loaded: false });
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

    const older = useProvenanceStore.getState().reload();
    await useProvenanceStore.getState().reload();
    expect(useProvenanceStore.getState().rows).toEqual(AFTER);

    slow.land({ status: "ok", data: BEFORE });

    // The overtaken read writes nothing, and says the rows are current
    // because the read that overtook it has already landed them.
    expect(await older).toBe(true);
    expect(useProvenanceStore.getState().rows).toEqual(AFTER);
  });

  // A caller about to act irreversibly waits on this boolean, so the answer
  // while a newer read is still coming is the closed one: the rows on screen
  // are neither this read's answer nor yet the newest.
  it("tells an overtaken read the rows are not current while a newer one is out", async () => {
    const slow = park();
    const newer = park();
    vi.mocked(commands.libraryProvenance)
      .mockReturnValueOnce(slow.promise)
      .mockReturnValueOnce(newer.promise);

    const older = useProvenanceStore.getState().reload();
    const outstanding = useProvenanceStore.getState().reload();
    slow.land({ status: "ok", data: BEFORE });

    expect(await older).toBe(false);
    expect(useProvenanceStore.getState().rows).toEqual([]);

    newer.land({ status: "ok", data: AFTER });
    expect(await outstanding).toBe(true);
    expect(useProvenanceStore.getState().rows).toEqual(AFTER);
  });
});
