import { describe, expect, it } from "vitest";
import { showEverythingLabel } from "./show-everything-label";

describe("showEverythingLabel", () => {
  it("separates two projects whose folders share a name", () => {
    expect(showEverythingLabel("client", "/work/client")).not.toBe(
      showEverythingLabel("client", "/personal/client"),
    );
  });

  it("keeps the visible name and the available path in the accessible label", () => {
    const rows = [
      {
        name: "project folder",
        label: "client",
        path: "/work/client",
        expected: "Show everything in client, /work/client",
      },
      {
        name: "no folder",
        label: "Personal",
        path: undefined,
        expected: "Show everything in Personal",
      },
      {
        name: "empty folder",
        label: "Personal",
        path: "",
        expected: "Show everything in Personal",
      },
    ];
    expect(rows.length, "show everything label table is empty").toBeGreaterThan(
      0,
    );
    for (const row of rows)
      expect(showEverythingLabel(row.label, row.path), row.name).toBe(
        row.expected,
      );
  });
});
