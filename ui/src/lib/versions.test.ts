import { describe, expect, it } from "vitest";
import type { VersionRow } from "@/bindings";
import { canUpdatePackage } from "./versions";

const version = (overrides: Partial<VersionRow> = {}): VersionRow => ({
  id: "b".repeat(40),
  label: "v2",
  date: "2026-01-01",
  summary: "two",
  installed: false,
  newerThanInstalled: true,
  ...overrides,
});

const page = (
  overrides: Partial<Parameters<typeof canUpdatePackage>[0]> = {},
) =>
  ({
    latest: version(),
    installed: version({ id: "a".repeat(40), installed: true, label: "v1" }),
    metaLoaded: true,
    withheld: null,
    ...overrides,
  }) satisfies Parameters<typeof canUpdatePackage>[0];

describe("canUpdatePackage", () => {
  it("offers Update for a following package with a newer version", () => {
    expect(canUpdatePackage(page())).toBe(true);
  });

  // Whatever withholds the update, the page hides the button — and the
  // page renders this same string beside it, so the two never disagree.
  // The reason itself is `update-groups.ts`'s to work out.
  it("never offers it while anything is withheld, whatever the reason", () => {
    expect(canUpdatePackage(page({ withheld: "any reason at all" }))).toBe(
      false,
    );
  });

  it("waits for what it needs", () => {
    expect(canUpdatePackage(page({ latest: undefined }))).toBe(false);
    expect(canUpdatePackage(page({ installed: undefined }))).toBe(false);
    expect(canUpdatePackage(page({ metaLoaded: false }))).toBe(false);
    expect(
      canUpdatePackage(page({ latest: version({ installed: true }) })),
    ).toBe(false);
  });
});
