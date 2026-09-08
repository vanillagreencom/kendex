import { describe, expect, it } from "vitest";
import type { ObservedItem } from "@/bindings";
import { filterItems, groupItems } from "./derive";

function item(overrides: Partial<ObservedItem>): ObservedItem {
  return {
    kind: "skill",
    name: "deploy",
    harness: "claude",
    scope: { scope: "global" },
    path: "/h/.claude/skills/deploy",
    fileState: { state: "dir" },
    enabled: true,
    origin: null,
    description: null,
    tags: [],
    modifiedAt: null,
    vendor: null,
    ...overrides,
  };
}

describe("filterItems by tag", () => {
  it("keeps the selected tag and leaves an absent filter open", () => {
    const rows: {
      name: string;
      items: ObservedItem[];
      tag?: "review";
      expected: string[];
    }[] = [
      {
        name: "selected tag",
        items: [
          item({ name: "reviewer", tags: ["review", "testing"] }),
          item({ name: "shipper", tags: ["release"] }),
          item({ name: "untagged" }),
        ],
        tag: "review",
        expected: ["reviewer"],
      },
      {
        name: "no tag filter",
        items: [item({ name: "a" }), item({ name: "b", tags: ["docs"] })],
        expected: ["a", "b"],
      },
    ];
    expect(rows.length, "tag filter table is empty").toBeGreaterThan(0);
    for (const row of rows)
      expect(
        filterItems(row.items, { scope: "all", tag: row.tag }).map(
          (one) => one.name,
        ),
        row.name,
      ).toEqual(row.expected);
  });
});

describe("groupItems tags", () => {
  it("unions the tags of all installations without duplicates", () => {
    const rows = [
      {
        name: "different installations",
        items: [
          item({ harness: "claude", tags: ["review", "testing"] }),
          item({ harness: "pi", tags: ["testing", "docs"] }),
        ],
        expected: ["review", "testing", "docs"],
      },
      { name: "no tags", items: [item({})], expected: [] },
    ];
    expect(rows.length, "grouped tag table is empty").toBeGreaterThan(0);
    for (const row of rows)
      expect(groupItems(row.items)[0].tags, row.name).toEqual(row.expected);
  });
});
