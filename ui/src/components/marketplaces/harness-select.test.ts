import { expect, it } from "vitest";
import { type Choice, isInstallable } from "./harness-select";

it("distinguishes an untouched, emptied and populated install choice", () => {
  const rows: {
    name: string;
    harnesses: Choice["harnesses"];
    allowed: boolean;
  }[] = [
    { name: "untouched: the scope decides", harnesses: null, allowed: true },
    { name: "emptied by hand", harnesses: [], allowed: false },
    { name: "a real selection", harnesses: ["claude"], allowed: true },
  ];
  expect(rows).toHaveLength(3);
  for (const row of rows) {
    expect(
      isInstallable({ harnesses: row.harnesses, method: null, optional: [] }),
      row.name,
    ).toBe(row.allowed);
  }
});
