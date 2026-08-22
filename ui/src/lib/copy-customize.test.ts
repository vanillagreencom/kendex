import { describe, expect, it } from "vitest";
import type { HookDelivery } from "@/bindings";
import {
  customizedPlacesLabel,
  forkedInLabel,
  hookDeliverySummary,
  placeStateLine,
} from "@/lib/copy-customize";

// The line under a hook is built from delivery rows the engine computed —
// these tests pin the composition, so no string literal in the UI can
// claim an enforcement the engine didn't decide.
describe("hookDeliverySummary", () => {
  const row = (
    harness: HookDelivery["harness"],
    mode: HookDelivery["mode"],
  ): HookDelivery => ({ harness, mode, note: null });

  it("says where a hook runs and where it is only guidance", () => {
    const line = hookDeliverySummary([
      row("claude", "runs"),
      row("codex", "runs"),
      row("cursor", "instructions"),
    ]);
    expect(line).toBe(
      "Runs in Claude Code and Codex · guidance only in Cursor — nothing enforces it there",
    );
  });

  it("counts Claude's per-agent block as running", () => {
    expect(hookDeliverySummary([row("claude", "runs-in-agent-file")])).toBe(
      "Runs in Claude Code",
    );
  });

  it("names the harnesses a hook cannot run in at all", () => {
    expect(hookDeliverySummary([row("cursor", "unavailable")])).toBe(
      "Can't run in Cursor",
    );
  });

  it("says nothing for an empty set", () => {
    expect(hookDeliverySummary([])).toBe("");
  });
});

// A mark that says "Customized" and nothing else answers "did you ever
// touch this anywhere" — never the question being asked, which is whether
// this place is yours.
describe("per-place marks", () => {
  it("names the place when the package lives in only one", () => {
    expect(customizedPlacesLabel(["vg"], 1, 0)).toBe("Customized in vg");
  });

  it("names where the mark leads, and counts the places behind it", () => {
    expect(customizedPlacesLabel(["vg"], 3, 0)).toBe(
      "Customized in vg · 1 of 3 places",
    );
    // The first named place is the one the click opens.
    expect(customizedPlacesLabel(["vg", "Personal"], 3, 0)).toBe(
      "Customized in vg · 2 of 3 places",
    );
  });

  it("never lets a count imply a place it could not read", () => {
    expect(customizedPlacesLabel(["vg"], 3, 1)).toBe(
      "Customized in vg · 1 of 3 places · 1 not checked",
    );
  });

  it("says what is known about one place, including that nothing is", () => {
    expect(placeStateLine("vg", "customized")).toBe("vg — customized by you");
    expect(placeStateLine("vg", "as-installed")).toBe(
      "vg — as the author wrote it",
    );
    expect(placeStateLine("vg", "unknown")).toBe(
      "vg — not checked for your changes",
    );
    // A read on its way has not failed, and must not be blamed as one.
    expect(placeStateLine("vg", "checking")).toBe("vg — still being checked");
  });

  it("names the places a fork belongs to", () => {
    expect(forkedInLabel(["vg", "Personal"])).toBe("Forked in vg, Personal");
  });
});
