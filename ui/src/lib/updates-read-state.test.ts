import { describe, expect, it } from "vitest";
import type { ScanWarning } from "@/bindings";
import type { PackageOf } from "@/lib/package-identity";
import {
  READ_LANDED,
  READ_PENDING,
  type ReadState,
  readFailed,
} from "@/lib/read-state";
import {
  rowsCountable,
  rowsKnown,
  scannedInstalled,
} from "@/lib/updates-read-state";
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

// Two rules over one set of rows, and which one a surface takes decides
// whether a number reaches the page. A fact is about one place and outlives
// a re-check that failed over the rows it kept — the fork badge, the edit,
// the places a package's files are gone from. A number is about all of them
// at once, and that set is precisely what the failed check was asked to
// confirm.
describe("what the update rows may be read as", () => {
  const kept = [{ kind: "skill", name: "deploy" }];

  it("tells a fact from a number for every read a page can be in", () => {
    const rows: [string, ReadState, unknown[], boolean, boolean][] = [
      ["a read that landed answers both", READ_LANDED, kept, true, true],
      ["a landed read over no rows answers both", READ_LANDED, [], true, true],
      [
        "a failed re-check keeps its facts and loses its number",
        readFailed("no network"),
        kept,
        true,
        false,
      ],
      [
        "a first read that failed has neither",
        readFailed("no network"),
        [],
        false,
        false,
      ],
      ["a read still on its way has neither", READ_PENDING, kept, false, false],
    ];
    expect(rows).toHaveLength(5);
    for (const [name, read, rows_, known, countable] of rows) {
      expect(rowsKnown({ read, rows: rows_ }), name).toBe(known);
      expect(rowsCountable({ read }), name).toBe(countable);
    }
  });
});
