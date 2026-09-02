import { describe, expect, it } from "vitest";
import { SEE_PROBLEMS_LABEL } from "@/lib/copy-marketplaces";
import {
  UPDATES_UNREADABLE_TITLE,
  unreadableProjectsLabel,
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
    expect(rows[0]?.detail).toBe(unreadableProjectsLabel(["hyprtrade"]));
    expect(rows[0]?.action?.label).toBe(SEE_PROBLEMS_LABEL);
  });
});
