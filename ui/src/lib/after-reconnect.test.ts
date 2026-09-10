import { describe, expect, it } from "vitest";
import type { ScanResult } from "@/bindings";
import type { BlockedPlace } from "@/lib/audit-counts";
import type { Problem } from "@/stores/problems";
import { afterReconnect } from "./after-reconnect";

const ROOT = "/work/vsys";
const here = { scope: "project" as const, root: ROOT };
const elsewhere = { scope: "project" as const, root: "/work/other" };

/** One place with `rows` blocked items in it. The count a person reads is
 *  the items, and one place holds every one of them at that folder. */
const blocked = (scope: BlockedPlace["scope"], rows = 1): BlockedPlace =>
  ({
    key: "k",
    scope,
    rows: Array.from({ length: rows }, (_, at) => ({ name: `item${at}` })),
    exits: null,
    alsoApplies: false,
  }) as never;
const problem = (scope: Problem["scope"]): Problem => ({
  key: "k",
  scope,
  kind: "lock-corrupt",
  message: "no",
});

/** A landed scan that opened `readProjects` and nothing else. */
const read = (...readProjects: string[]): ScanResult =>
  ({
    items: [],
    harnesses: [],
    warnings: [],
    missingProjects: [],
    readProjects,
  }) as never;

/** The scan that read the folder every case below is about. */
const READ_HERE = read(ROOT);

describe("what the read after a reconnect says about the new folder", () => {
  it("counts the items at that folder, not the places holding them", () => {
    expect(
      afterReconnect(
        [],
        [blocked(here, 3), blocked(elsewhere, 2)],
        [],
        READ_HERE,
        ROOT,
      ),
    ).toEqual({ state: "problems", count: 3 });
    expect(
      afterReconnect([], [blocked(elsewhere)], [], READ_HERE, ROOT),
    ).toEqual({
      state: "clean",
    });
  });

  // A file the scan could not read is a repair Problems draws for this
  // folder, and it is in no audit row: counting only the audit's rows is
  // how the line says nothing needs doing over a page that offers one.
  it("counts the files the scan could not read here", () => {
    const warning = (path: string) => ({ path }) as never;
    expect(
      afterReconnect(
        [],
        [],
        [warning(`${ROOT}/.claude/settings.json`), warning("/work/other/x")],
        READ_HERE,
        ROOT,
      ),
    ).toEqual({ state: "problems", count: 1 });
  });

  // The paths are serialized `PathBuf`s, so on Windows they are spelled
  // with the separator that machine uses. A containment test for one
  // separator reports every project there clean.
  it("counts them whichever separator the machine spells paths with", () => {
    const warning = (path: string) => ({ path }) as never;
    expect(
      afterReconnect(
        [],
        [],
        [warning(String.raw`C:\work\app\.claude\settings.json`)],
        read(String.raw`C:\work\app`),
        String.raw`C:\work\app`,
      ),
    ).toEqual({ state: "problems", count: 1 });
  });

  // The one claim this must never make: a place kendex could not read is
  // not a place kendex found nothing wrong with.
  it("claims nothing where the read could not answer", () => {
    expect(afterReconnect([], null, [], READ_HERE, ROOT)).toEqual({
      state: "unchecked",
    });
    expect(afterReconnect([problem(here)], [], [], READ_HERE, ROOT)).toEqual({
      state: "unchecked",
    });
    // A scan that could not finish is a problem about the machine, and
    // the read that would have covered this folder is the one that
    // failed: nothing here may be called clean on it.
    expect(afterReconnect([problem(null)], [], [], READ_HERE, ROOT)).toEqual({
      state: "unchecked",
    });
  });

  // The scan landing is not this folder being read. A scan that could not
  // open the destination reports it missing and leaves it out of what it
  // read; nothing then holds a row for it, and every count above comes to
  // zero — the shape of a folder with nothing wrong in it. The one bit
  // that tells the two apart is whether the folder was opened.
  it("claims nothing about a folder the scan could not open", () => {
    expect(afterReconnect([], [], [], read("/work/other"), ROOT)).toEqual({
      state: "unchecked",
    });
    // And before any scan has landed at all.
    expect(afterReconnect([], [], [], null, ROOT)).toEqual({
      state: "unchecked",
    });
  });
});
