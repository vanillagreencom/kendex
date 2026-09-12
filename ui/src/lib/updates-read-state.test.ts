import { describe, expect, it } from "vitest";
import type { PackageOf } from "@/lib/package-identity";
import { scannedInstalled } from "@/lib/updates-read-state";
import { observedSkill, scanFound } from "@/test/observed";

/** A join that recognises nothing, so fixtures group as the scan saw them. */
const joined: PackageOf = () => null;

// Every reading but a settled, complete, successful scan is null and not
// zero, because the caller words a zero as "Nothing installed yet".
describe("the installed count an empty Updates page may be read from", () => {
  it("counts only what a settled, complete, successful scan found", () => {
    const rows = [
      {
        name: "counts an empty machine as empty",
        scan: scanFound([]),
        error: null,
        packageOf: joined,
        count: 0,
      },
      {
        name: "counts the packages a scan found",
        scan: scanFound([observedSkill("deploy"), observedSkill("review")]),
        error: null,
        packageOf: joined,
        count: 2,
      },
      {
        name: "takes no count before the scan has landed",
        scan: null,
        error: null,
        packageOf: joined,
        count: null,
      },
      {
        name: "takes no count from a result kept behind a failed scan",
        scan: scanFound([]),
        error: "config unreadable",
        packageOf: joined,
        count: null,
      },
      {
        name: "takes no count from a scan that could not read a project",
        scan: scanFound(
          [],
          [{ root: "/work/hyprtrade", why: { kind: "gone" } }],
        ),
        error: null,
        packageOf: joined,
        count: null,
      },
      {
        name: "takes no count from a join that answers about another scan",
        scan: scanFound([]),
        error: null,
        packageOf: null,
        count: null,
      },
    ];
    expect(rows).toHaveLength(6);
    for (const row of rows) {
      expect(
        scannedInstalled(row.scan, row.error, row.packageOf),
        row.name,
      ).toBe(row.count);
    }
  });
});
