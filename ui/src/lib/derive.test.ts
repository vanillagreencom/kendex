import { describe, expect, it } from "vitest";
import { observedItem as item } from "@/lib/observed-test-item";
import {
  bundleSummary,
  countByKind,
  filterItems,
  groupItems,
  groupVendor,
  recentItems,
  scopeMatches,
} from "./derive";

describe("scopeMatches", () => {
  it("matches all, global, and specific projects", () => {
    const global = item({});
    const project = item({ scope: { scope: "project", root: "/p" } });
    expect(scopeMatches(global, "all")).toBe(true);
    expect(scopeMatches(global, "global")).toBe(true);
    expect(scopeMatches(global, { project: "/p" })).toBe(false);
    expect(scopeMatches(project, "global")).toBe(false);
    expect(scopeMatches(project, { project: "/p" })).toBe(true);
    expect(scopeMatches(project, { project: "/other" })).toBe(false);
  });
});

describe("filterItems", () => {
  const items = [
    item({ name: "deploy" }),
    item({ name: "review", kind: "agent", harness: "pi" }),
    item({ name: "gh", description: "github helper" }),
  ];

  it("filters by kind, harness, and search over name+description", () => {
    expect(filterItems(items, { scope: "all", kind: "agent" })).toHaveLength(1);
    expect(filterItems(items, { scope: "all", harness: "pi" })).toHaveLength(1);
    expect(filterItems(items, { scope: "all", search: "GITHUB" })).toHaveLength(
      1,
    );
    expect(filterItems(items, { scope: "all" })).toHaveLength(3);
  });
});

describe("filterItems by where it lives", () => {
  const items = [
    item({ name: "a", scope: { scope: "project", root: "/a" } }),
    item({ name: "b", scope: { scope: "project", root: "/b" } }),
    item({ name: "g", scope: { scope: "global" } }),
  ];

  it("narrows to one project, to personal, or to everything", () => {
    expect(filterItems(items, { scope: { project: "/a" } })).toHaveLength(1);
    expect(filterItems(items, { scope: "global" })).toHaveLength(1);
    expect(filterItems(items, { scope: "all" })).toHaveLength(3);
  });

  it("combines where it lives with the other filters", () => {
    expect(
      filterItems(items, { scope: { project: "/a" }, search: "b" }),
    ).toHaveLength(0);
    expect(
      filterItems(items, { scope: { project: "/a" }, search: "a" }),
    ).toHaveLength(1);
  });
});

describe("countByKind", () => {
  it("tallies per kind", () => {
    const counts = countByKind([
      item({}),
      item({ name: "x" }),
      item({ kind: "agent" }),
    ]);
    expect(counts.get("skill")).toBe(2);
    expect(counts.get("agent")).toBe(1);
  });
});

describe("recentItems", () => {
  it("sorts by modifiedAt descending and drops groups with no timestamp", () => {
    const groups = groupItems([
      item({ name: "old", modifiedAt: 100 }),
      item({ name: "new", modifiedAt: 300 }),
      item({ name: "mid", modifiedAt: 200 }),
      item({ name: "never", modifiedAt: null }),
    ]);
    expect(recentItems(groups, 10).map((g) => g.name)).toEqual([
      "new",
      "mid",
      "old",
    ]);
  });

  it("caps at the requested limit", () => {
    const groups = groupItems([
      item({ name: "a", modifiedAt: 1 }),
      item({ name: "b", modifiedAt: 2 }),
      item({ name: "c", modifiedAt: 3 }),
    ]);
    expect(recentItems(groups, 2)).toHaveLength(2);
  });
});

describe("bundleSummary", () => {
  it("lists what a bundle carries", () => {
    expect(bundleSummary(["skill dev", "agent writer"])).toBe(
      "skill dev, agent writer",
    );
  });

  it("counts the rest once the list would run long", () => {
    const members = ["a", "b", "c", "d", "e", "f"];
    expect(bundleSummary(members)).toBe("a, b, c, d, and 2 more");
  });

  it("says so when a bundle carries nothing", () => {
    expect(bundleSummary([])).toBe("Carries nothing yet");
  });
});

describe("groupVendor", () => {
  it("names the vendor only when every installation agrees it is theirs", () => {
    const bundled = groupItems([
      item({ kind: "plugin", name: "chrome@openai-bundled", vendor: "OpenAI" }),
      item({
        kind: "plugin",
        name: "chrome@openai-bundled",
        harness: "codex",
        vendor: "OpenAI",
      }),
    ]);
    expect(groupVendor(bundled[0])).toBe("OpenAI");

    const mixed = groupItems([
      item({ kind: "plugin", name: "gh", vendor: "OpenAI" }),
      item({ kind: "plugin", name: "gh", harness: "codex", vendor: null }),
    ]);
    expect(groupVendor(mixed[0])).toBeNull();
  });
});
