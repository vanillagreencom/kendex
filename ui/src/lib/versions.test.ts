import { describe, expect, it } from "vitest";
import { PER_PACKAGE_UPDATE_KINDS, type VersionRow } from "@/bindings";
import { canUpdatePackage, hasPerPackageUpdate } from "./versions";

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
    kind: "skill" as const,
    latest: version(),
    installed: version({ id: "a".repeat(40), installed: true, label: "v1" }),
    metaLoaded: true,
    updatesLoaded: true,
    edited: false,
    ...overrides,
  }) satisfies Parameters<typeof canUpdatePackage>[0];

describe("hasPerPackageUpdate", () => {
  // Core owns the list; this asserts the UI reads that one and keeps no
  // copy, so the button and the refusal behind it cannot drift apart.
  it("admits exactly the kinds core says a plan brings current on its own", () => {
    for (const kind of PER_PACKAGE_UPDATE_KINDS) {
      expect(hasPerPackageUpdate(kind)).toBe(true);
    }
    expect(hasPerPackageUpdate("pi-extension")).toBe(false);
    expect(hasPerPackageUpdate("plugin")).toBe(false);
  });
});

describe("canUpdatePackage", () => {
  it("offers Update for a following package with a newer version", () => {
    expect(canUpdatePackage(page())).toBe(true);
  });

  // The button routes to the single-package apply, which refuses these
  // kinds outright: offering it could only fail.
  it("never offers it for a kind the planner does not bring current", () => {
    expect(canUpdatePackage(page({ kind: "pi-extension" }))).toBe(false);
    expect(canUpdatePackage(page({ kind: "plugin" }))).toBe(false);
  });

  it("waits for what it needs and stands off an edited package", () => {
    expect(canUpdatePackage(page({ latest: undefined }))).toBe(false);
    expect(canUpdatePackage(page({ installed: undefined }))).toBe(false);
    expect(canUpdatePackage(page({ metaLoaded: false }))).toBe(false);
    expect(canUpdatePackage(page({ updatesLoaded: false }))).toBe(false);
    expect(canUpdatePackage(page({ edited: true }))).toBe(false);
    expect(
      canUpdatePackage(page({ latest: version({ installed: true }) })),
    ).toBe(false);
  });
});
