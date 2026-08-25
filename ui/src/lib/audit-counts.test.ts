import { describe, expect, it } from "vitest";
import type { AuditView, DriftRow, HarnessId } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { unmanagedCount } from "./audit-counts";

function drift(
  name: string,
  harness: HarnessId,
  state: DriftRow["state"],
  root?: string,
): DriftRow {
  return {
    kind: "skill",
    name,
    harness,
    scope: root ? { scope: "project", root } : { scope: "global" },
    state,
    detail: "",
  };
}

function view(rows: DriftRow[], root?: string): AuditView {
  return {
    scope: root ? { scope: "project", root } : { scope: "global" },
    drift: rows,
    plan: [],
    notes: [],
    warnings: [],
    safety: [],
    adoptable: ADOPTABLE,
    exits: [],
  };
}

describe("unmanagedCount", () => {
  it("counts one item installed for five tools once", () => {
    const tools: HarnessId[] = ["claude", "codex", "opencode", "cursor", "pi"];
    const rows = tools.map((h) => drift("agent-browser", h, "unmanaged"));

    expect(unmanagedCount(view(rows))).toBe(1);
  });

  it("counts each place on its own, never folding two projects together", () => {
    const personal = view([drift("github", "claude", "unmanaged")]);
    const project = view([drift("github", "claude", "unmanaged", "/p")], "/p");

    expect(unmanagedCount(personal)).toBe(1);
    expect(unmanagedCount(project)).toBe(1);
  });

  it("counts only what was never adopted, not pending writes", () => {
    const rows = [
      drift("a", "claude", "stale"),
      drift("b", "claude", "missing"),
      drift("c", "claude", "unmanaged"),
    ];

    expect(unmanagedCount(view(rows))).toBe(1);
  });
});
