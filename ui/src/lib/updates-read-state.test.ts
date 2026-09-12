import { describe, expect, it } from "vitest";
import type { ScanWarning } from "@/bindings";
import type { PackageOf } from "@/lib/package-identity";
import { scannedInstalled } from "@/lib/updates-read-state";
import { observedSkill, scanFound } from "@/test/observed";

/** A join that recognises nothing, so fixtures group as the scan saw them. */
const joined: PackageOf = () => null;

/** A surface the scan could not read, still asking the reader to act. */
const unread: ScanWarning = {
  harness: "claude",
  kind: "skill",
  path: "/h/.claude/skills",
  problem: { kind: "unreadable", message: "denied" },
  standing: "actionable",
};

// Every reading but a whole-machine scan is null, not zero: the caller
// words a zero as "Nothing installed yet".
describe("the installed count an empty Updates page may be read from", () => {
  it("counts only what a settled, complete, successful scan found", () => {
    const rows = [
      {
        name: "counts an empty machine as empty",
        scan: scanFound([]),
        packageOf: joined,
        count: 0,
      },
      {
        name: "counts the packages a scan found",
        scan: scanFound([observedSkill("deploy"), observedSkill("review")]),
        packageOf: joined,
        count: 2,
      },
      {
        name: "takes no count before the scan has landed",
        scan: null,
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
        scan: scanFound([], [{ root: "/p", why: { kind: "gone" } }]),
        packageOf: joined,
        count: null,
      },
      {
        name: "takes no count from a scan warning about a surface it could not read",
        scan: scanFound([], [], [unread]),
        packageOf: joined,
        count: null,
      },
      {
        name: "takes no count from a join that answers about another scan",
        scan: scanFound([]),
        packageOf: null,
        count: null,
      },
    ];
    expect(rows).toHaveLength(7);
    for (const row of rows) {
      expect(
        scannedInstalled(row.scan, row.error ?? null, row.packageOf),
        row.name,
      ).toBe(row.count);
    }
  });
});
