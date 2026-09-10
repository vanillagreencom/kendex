import { describe, expect, it } from "vitest";
import type { MissingProject, Standing } from "@/bindings";
import {
  MISSING_PROJECTS_DETAIL,
  missingProjectDetail,
  standingSaid,
} from "./copy-project-move";

const missing = (why: MissingProject["why"]): MissingProject =>
  ({ root: "/work/vsys", why }) as never;

describe("what Home says to do about a project folder it could not read", () => {
  // A folder that is gone and a path something else took are both
  // answered by pointing the project somewhere else. A folder this
  // machine could not read is not: it never moved, and the way back is
  // the permission or the disk, then another read.
  it("names the repair the reading actually has", () => {
    for (const why of [
      { kind: "gone" as const },
      { kind: "not-a-folder" as const },
    ]) {
      expect(missingProjectDetail(missing(why))).toContain(
        "point it at the folder it is in now",
      );
    }
    const unreadable = missingProjectDetail(
      missing({ kind: "unreadable", said: "Permission denied (os 13)" }),
    );
    expect(unreadable).toContain("read it again once it can be reached");
    expect(unreadable).not.toContain("point it at");
  });

  // One line stands for a list that can hold all three, so it names no
  // repair at all rather than the wrong one for some of them.
  it("names no single repair for a list of them", () => {
    expect(MISSING_PROJECTS_DETAIL).not.toContain("point");
    expect(MISSING_PROJECTS_DETAIL).toContain("Projects");
  });
});

describe("what the picked folder is said to hold", () => {
  // An absent record says a record was not found, and nothing more: one
  // can be deleted, and a folder can be restored with kendex-managed
  // files still in it. The person is deciding whether to reconnect here,
  // which is exactly where an unsupported claim costs something.
  it("describes a missing record rather than claiming the folder is empty", () => {
    const said = standingSaid({ kind: "no-record" } as Standing, "vsys");
    expect(said).toContain("no kendex record");
    expect(said).not.toContain("installed nothing");
  });
});
