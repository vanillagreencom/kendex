import { describe, expect, it } from "vitest";
import { SEE_PROBLEMS_LABEL } from "@/lib/copy-marketplaces";
import {
  UPDATES_UNREADABLE_TITLE,
  unreadablePlacesLabel,
} from "@/lib/copy-updates";
import { type AttentionSource, attentionRows } from "./attention-rows";

const clean: AttentionSource = {
  editedPackages: [],
  result: null,
  updatesError: null,
  auditError: null,
  unreadable: [],
  onProjects: () => {},
  onProblems: () => {},
  onUpdates: () => {},
  onLibrary: () => {},
  onPackage: () => {},
  onAuditRetry: () => {},
};

// A project with no update standing is missing from every count Home
// shows. It used to reach this list only as a whole-read failure; carried
// as its own row it names the project instead of the machine.
describe("a project Home has no update standing for", () => {
  it("is not mentioned when nothing failed", () => {
    expect(attentionRows(clean)).toEqual([]);
  });

  it("names the project and points at Problems", () => {
    const rows = attentionRows({
      ...clean,
      unreadable: [
        {
          scope: { scope: "project", root: "/home/dev/hyprtrade" },
          message: "it is a version 5 record",
        },
      ],
    });
    expect(rows).toHaveLength(1);
    expect(rows[0]?.title).toBe(UPDATES_UNREADABLE_TITLE);
    expect(rows[0]?.detail).toBe(unreadablePlacesLabel(["hyprtrade"]));
    expect(rows[0]?.action?.label).toBe(SEE_PROBLEMS_LABEL);
  });

  // The update read folds every scope, so a personal lock this build
  // refuses lands here too. It is named as what it is rather than being
  // counted among the projects.
  it("names the personal scope as Personal, not as a project", () => {
    const rows = attentionRows({
      ...clean,
      unreadable: [
        { scope: { scope: "global" }, message: "it is a version 5 record" },
      ],
    });
    expect(rows[0]?.detail).toBe(unreadablePlacesLabel(["Personal"]));
  });

  // A folder basename is not unique: two projects with the same one would
  // be named twice over identically, with nothing saying which failed.
  it("tells apart two projects whose folders share a name", () => {
    const rows = attentionRows({
      ...clean,
      unreadable: [
        {
          scope: { scope: "project", root: "/home/dev/kendex" },
          message: "it is a version 5 record",
        },
        {
          scope: { scope: "project", root: "/home/work/kendex" },
          message: "it is a version 5 record",
        },
      ],
    });
    expect(rows[0]?.detail).toBe(
      unreadablePlacesLabel(["/home/dev/kendex", "/home/work/kendex"]),
    );
  });
});
