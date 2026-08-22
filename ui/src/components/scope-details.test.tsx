import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { DriftRow, ItemSafety } from "@/bindings";
import { mergeDriftRows, reviewLists } from "@/lib/drift-merge";
import { ScopeChanges, ScopeConflicts } from "./scope-details";

const conflict = (over: Partial<DriftRow> = {}): DriftRow => ({
  kind: "skill",
  name: "gh",
  harness: "claude",
  scope: { scope: "project", root: "/work/vg" },
  state: "conflict",
  subject: "package",
  detail: "edited on disk since your fork was rendered",
  cause: "local-edit",
  ...over,
});

// Apply runs a plan, and a conflict has no ops behind it. Filing one under
// "Ready to apply" counts it as work a button can do and offers no button.
describe("a conflict in the Review card", () => {
  it("is not counted or headed as ready to apply", () => {
    const stale = conflict({ name: "rev", state: "stale" });
    const lists = reviewLists([conflict(), stale], []);
    expect(lists.changes.map((one) => one.name)).toEqual(["rev"]);
    expect(lists.conflicts.map((one) => one.name)).toEqual(["gh"]);
    expect(
      renderToStaticMarkup(<ScopeChanges changes={lists.changes} />),
    ).not.toContain(">gh<");
  });

  it("is listed where its exits are, with the way to them", () => {
    const onOpen = vi.fn();
    const html = renderToStaticMarkup(
      <ScopeConflicts
        conflicts={mergeDriftRows([conflict()])}
        onOpen={onOpen}
      />,
    );
    expect(html).toContain("Waiting on you, on their own pages");
    expect(html).toContain("<button");
    expect(html).toContain(">gh<");
  });

  // The gate emits a conflict for an install it refused, and that refusal
  // is already on offer above with the accept and dismiss that settle it.
  // No package page can settle a safety decision, so a second listing here
  // sends the person somewhere that cannot help.
  it("is not repeated where the safety decision already is", () => {
    const refused: ItemSafety = {
      kind: "skill",
      name: "gh",
      harness: "claude",
      scope: { scope: "project", root: "/work/vg" },
      location: "",
      safety: { score: 10, deductions: [] },
      quality: null,
      findings: [],
      skipped: [],
      verdict: "block",
      reasons: [],
      contentHash: "c",
      reviewHash: "h",
      provenance: null,
      override: { state: "absent" },
      decisions: [],
    };
    const lists = reviewLists(
      [conflict(), conflict({ name: "rev" })],
      [refused],
    );
    expect(lists.conflicts.map((one) => one.name)).toEqual(["rev"]);
  });

  it("says nothing when there is no conflict", () => {
    expect(
      renderToStaticMarkup(<ScopeConflicts conflicts={[]} onOpen={() => {}} />),
    ).toBe("");
  });

  // Not every conflict is a package. The engine synthesises one for a
  // settings file it writes beside them, and a link there would navigate
  // to something the scan cannot contain.
  it("is plain text where there is no package page to open", () => {
    const html = renderToStaticMarkup(
      <ScopeConflicts
        conflicts={mergeDriftRows([
          conflict({ name: ".kendex-settings.env", subject: "scope" }),
        ])}
        onOpen={() => {}}
      />,
    );
    expect(html).not.toContain("<button");
    expect(html).toContain(">.kendex-settings.env<");
  });
});
