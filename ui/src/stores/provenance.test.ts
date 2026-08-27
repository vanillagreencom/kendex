import { describe, expect, it } from "vitest";
import type { ProvenanceRow } from "@/bindings";
import { originFor, originLabel, originTitle } from "./provenance";

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
