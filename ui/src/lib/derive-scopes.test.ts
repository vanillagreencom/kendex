import { describe, expect, it } from "vitest";
import type { ObservedItem, ScanResult } from "@/bindings";
import { scopeChoices } from "./derive";

function result(roots: string[]): ScanResult {
  const items: ObservedItem[] = roots.map((root) => ({
    kind: "skill",
    name: "deploy",
    harness: "claude",
    scope: { scope: "project", root },
    path: `${root}/.claude/skills/deploy`,
    fileState: { state: "dir" },
    enabled: true,
    origin: null,
    description: null,
    tags: [],
    modifiedAt: null,
    vendor: null,
  }));
  return { harnesses: [], items, missingProjects: [], warnings: [] };
}

describe("scopeChoices", () => {
  it("offers every project holding something", () => {
    expect(scopeChoices(result(["/b", "/a", "/a"]), "all")).toEqual([
      "/a",
      "/b",
    ]);
  });

  it("offers the project being looked at even when it holds nothing", () => {
    // Picked last, listed in its place: the pills read the same however the
    // project came to be one of them.
    expect(scopeChoices(result(["/z"]), { project: "/empty" })).toEqual([
      "/empty",
      "/z",
    ]);
    expect(scopeChoices(null, { project: "/empty" })).toEqual(["/empty"]);
  });

  it("names the picked project once when it holds something too", () => {
    expect(scopeChoices(result(["/a"]), { project: "/a" })).toEqual(["/a"]);
  });
});
