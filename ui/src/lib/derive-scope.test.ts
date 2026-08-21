import { describe, expect, it } from "vitest";
import type { AuditView } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { viewsInScope } from "./derive";

describe("viewsInScope", () => {
  const view = (scope: AuditView["scope"]): AuditView => ({
    scope,
    drift: [],
    plan: [],
    notes: [],
    warnings: [],
    safety: [],
    adoptable: ADOPTABLE,
    keepable: [],
    heldBack: [],
    queued: [],
  });
  const all = [
    view({ scope: "global" }),
    view({ scope: "project", root: "/a" }),
    view({ scope: "project", root: "/b" }),
  ];

  it("narrows to the picked scope and nothing else", () => {
    expect(viewsInScope(all, "all")).toHaveLength(3);
    expect(viewsInScope(all, "global").map((v) => v.scope.scope)).toEqual([
      "global",
    ]);
    expect(viewsInScope(all, { project: "/b" })).toEqual([all[2]]);
  });
});
