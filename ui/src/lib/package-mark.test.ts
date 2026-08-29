import { describe, expect, it } from "vitest";
import type { Scope, UpdateRow } from "@/bindings";
import { groupItems } from "@/lib/derive";
import { markFor } from "./package-mark";

const VG: Scope = { scope: "project", root: "/work/vg" };
const HYPR: Scope = { scope: "project", root: "/work/hyprtrade" };

const item = (scope: Scope) => ({
  kind: "skill",
  name: "gh",
  scope,
  harness: "claude",
  path: `${scope.scope === "project" ? scope.root : ""}/.claude/skills/gh`,
  fileState: "file",
  enabled: true,
  origin: null,
  description: "about gh",
  tags: [],
});

const group = groupItems([item(VG), item(HYPR)] as never)[0];

// Both places have been read for hand edits and forks, so a count over
// them is a count over places somebody looked at.
const rows = [VG, HYPR].map(
  (scope) =>
    ({
      scope,
      kind: "skill",
      name: "gh",
      source: "cat",
      repo: "o/r",
      repoIdentity: "o/r",
      current: null,
      latest: null,
      updateAvailable: false,
      pinned: false,
      holdOwner: null,
      ignored: false,
      blockedByLocalEdit: false,
      editedHarnesses: [],
      forkableHarness: null,
      canDiscard: false,
      forked: false,
    }) as unknown as UpdateRow,
);

// Customized in vg and nowhere else.
const saved = {
  "/work/vg": { schema: 1, install: {}, "skill-instructions": { gh: "mine" } },
  "/work/hyprtrade": { schema: 1, install: {} },
};

describe("markFor", () => {
  // The page names a place; the mark is about the package. Answering for
  // the place the page happened to open at is what let the Library row and
  // the package's header state two different facts under the same words.
  it("answers for the package, not for the place the page opened at", () => {
    expect(markFor(saved as never, rows, true, group)?.label).toBe(
      "Customized in vg · 1 of 2 projects",
    );
  });

  it("says nothing where no place holds anything", () => {
    const untouched = {
      "/work/vg": { schema: 1, install: {} },
      "/work/hyprtrade": { schema: 1, install: {} },
    };
    expect(markFor(untouched as never, rows, true, group)).toBeNull();
  });
});
