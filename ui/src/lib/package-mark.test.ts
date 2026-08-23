import { describe, expect, it } from "vitest";
import type { Scope } from "@/bindings";
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

// Customized in vg and nowhere else.
const saved = {
  "/work/vg": { schema: 1, install: {}, "skill-instructions": { gh: "mine" } },
  "/work/hyprtrade": { schema: 1, install: {} },
};

describe("markFor", () => {
  // The page reads this with the place it is about. Handed the editor's
  // open place instead, the same package answers differently — which is
  // what makes the argument worth pinning.
  it("answers for the place it is given", () => {
    expect(markFor(saved as never, [], true, group, VG)?.label).toBe(
      "Customized in vg",
    );
    expect(markFor(saved as never, [], true, group, HYPR)).toBeNull();
  });
});
