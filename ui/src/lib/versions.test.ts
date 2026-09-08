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
  it("requires current metadata and an allowed newer version", () => {
    const rows = [
      { name: "newer following package", input: page(), expected: true },
      {
        name: "withheld",
        input: page({ withheld: "any reason at all" }),
        expected: false,
      },
      {
        name: "no latest version",
        input: page({ latest: undefined }),
        expected: false,
      },
      {
        name: "no installed version",
        input: page({ installed: undefined }),
        expected: false,
      },
      {
        name: "metadata pending",
        input: page({ metaLoaded: false }),
        expected: false,
      },
      {
        name: "already installed latest",
        input: page({ latest: version({ installed: true }) }),
        expected: false,
      },
    ];
    expect(rows.length, "package update offer table is empty").toBeGreaterThan(
      0,
    );
    for (const row of rows)
      expect(canUpdatePackage(row.input), row.name).toBe(row.expected);
  });
});
