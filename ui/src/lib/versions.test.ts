import { describe, expect, it } from "vitest";
import type { VersionRow } from "@/bindings";
import { updateRow } from "@/components/updates-test-rows";
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
    updatesLoaded: true,
    row: updateRow("gh", "/proj"),
    ...overrides,
  }) satisfies Parameters<typeof canUpdatePackage>[0];

describe("canUpdatePackage", () => {
  it("offers Update for a following package with a newer version", () => {
    expect(canUpdatePackage(page())).toBe(true);
  });

  // The button routes to the single-package apply, which refuses a kind
  // core plans nothing for: offering it could only fail. The UI never
  // works the kind out for itself — the refusal is on the row.
  it("never offers it for a kind core refuses", () => {
    const refused = updateRow("gh", "/proj", {
      kind: "pi-extension",
      noPerPackageUpdate: "Not updated one package at a time",
    });
    expect(canUpdatePackage(page({ row: refused }))).toBe(false);
  });

  // A place the update read never spoke for is one the engine has no
  // declaration for either.
  it("never offers it for a place with no update row", () => {
    expect(canUpdatePackage(page({ row: null }))).toBe(false);
  });

  it("waits for what it needs and stands off an edited package", () => {
    expect(canUpdatePackage(page({ latest: undefined }))).toBe(false);
    expect(canUpdatePackage(page({ installed: undefined }))).toBe(false);
    expect(canUpdatePackage(page({ metaLoaded: false }))).toBe(false);
    expect(canUpdatePackage(page({ updatesLoaded: false }))).toBe(false);
    expect(
      canUpdatePackage(
        page({ row: updateRow("gh", "/proj", { blockedByLocalEdit: true }) }),
      ),
    ).toBe(false);
    expect(
      canUpdatePackage(page({ latest: version({ installed: true }) })),
    ).toBe(false);
  });
});
