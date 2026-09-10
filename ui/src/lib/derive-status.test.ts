import { describe, expect, it } from "vitest";
import type { ObservedItem } from "@/bindings";
import { observed } from "@/test/observed";
import { groupItems, groupStatus } from "./derive";

function item(overrides: Partial<ObservedItem>): ObservedItem {
  return observed({
    kind: "skill",
    name: "deploy",
    harness: "claude",
    scope: { scope: "global" },
    path: "/h/.claude/skills/deploy",
    fileState: { state: "dir" },
    enabled: true,
    origin: null,
    summary: null,
    action: null,
    tags: [],
    modifiedAt: null,
    vendor: null,
    ...overrides,
  });
}

const status = (items: ObservedItem[]) =>
  groupStatus(groupItems(items, () => null)[0]);

describe("groupStatus", () => {
  it("reports broken links before disabled copies", () => {
    const rows: {
      name: string;
      items: ObservedItem[];
      expected: ReturnType<typeof groupStatus>;
    }[] = [
      {
        name: "all active",
        items: [item({}), item({ harness: "codex" })],
        expected: "active",
      },
      {
        name: "one disabled",
        items: [item({}), item({ harness: "codex", enabled: false })],
        expected: "off",
      },
      {
        name: "disabled broken link",
        items: [
          item({
            enabled: false,
            fileState: { state: "symlink", target: "/gone", broken: true },
          }),
        ],
        expected: "broken",
      },
      {
        name: "live link",
        items: [
          item({
            fileState: {
              state: "symlink",
              target: "/src/deploy",
              broken: false,
            },
          }),
        ],
        expected: "active",
      },
    ];
    expect(rows.length, "group status table is empty").toBeGreaterThan(0);
    for (const row of rows)
      expect(status(row.items), row.name).toBe(row.expected);
  });
});
