import { describe, expect, it } from "vitest";
import { editorOpenPath } from "./editor-path";

describe("editorOpenPath", () => {
  it("opens skill folders and preserves other paths", () => {
    const rows = [
      {
        name: "Unix skill",
        path: "/home/user/.claude/skills/foo/SKILL.md",
        expected: "/home/user/.claude/skills/foo",
      },
      {
        name: "Windows skill",
        path: "C:\\Users\\u\\.claude\\skills\\foo\\SKILL.md",
        expected: "C:\\Users\\u\\.claude\\skills\\foo",
      },
      {
        name: "other file",
        path: "/home/user/.claude/hooks/pre-commit.sh",
        expected: "/home/user/.claude/hooks/pre-commit.sh",
      },
    ];
    expect(rows.length, "editor path table is empty").toBeGreaterThan(0);
    for (const row of rows)
      expect(editorOpenPath(row.path), row.name).toBe(row.expected);
  });
});
