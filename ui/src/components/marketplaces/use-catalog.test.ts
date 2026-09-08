import { expect, it } from "vitest";
import { readDue } from "./use-catalog";

it("reads an invalidated cache only when ready and not refused", () => {
  const rows = [
    {
      name: "the loaded slot is still present",
      present: true,
      failed: false,
      ready: true,
      due: false,
    },
    {
      name: "a mutation emptied the slot",
      present: false,
      failed: false,
      ready: true,
      due: true,
    },
    {
      name: "a refusal stands",
      present: false,
      failed: true,
      ready: true,
      due: false,
    },
    {
      name: "the catalog is not ready",
      present: false,
      failed: false,
      ready: false,
      due: false,
    },
  ];
  expect(rows).toHaveLength(4);
  for (const row of rows) {
    expect(readDue(row.present, row.failed, row.ready), row.name).toBe(row.due);
  }
});
