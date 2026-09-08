import { describe, expect, it } from "vitest";
import { isSearchShortcutKey } from "./search-shortcut";

describe("isSearchShortcutKey", () => {
  it("takes slash only outside editable fields", () => {
    const rows: {
      name: string;
      key: string;
      target: Parameters<typeof isSearchShortcutKey>[1];
      expected: boolean;
    }[] = [
      { name: "no target", key: "/", target: null, expected: true },
      { name: "div", key: "/", target: { tagName: "DIV" }, expected: true },
      {
        name: "button",
        key: "/",
        target: { tagName: "BUTTON" },
        expected: true,
      },
      { name: "letter", key: "a", target: null, expected: false },
      { name: "enter", key: "Enter", target: null, expected: false },
      {
        name: "input",
        key: "/",
        target: { tagName: "INPUT" },
        expected: false,
      },
      {
        name: "textarea",
        key: "/",
        target: { tagName: "TEXTAREA" },
        expected: false,
      },
      {
        name: "select",
        key: "/",
        target: { tagName: "SELECT" },
        expected: false,
      },
      {
        name: "editable div",
        key: "/",
        target: { tagName: "DIV", isContentEditable: true },
        expected: false,
      },
    ];
    expect(rows.length, "search shortcut table is empty").toBeGreaterThan(0);
    for (const row of rows)
      expect(isSearchShortcutKey(row.key, row.target), row.name).toBe(
        row.expected,
      );
  });
});
