import { expect, it } from "vitest";
import type { HarnessId } from "@/bindings";
import { type Choice, isInstallable } from "./harness-select";

it("installs only where the choice, or the scope's defaults behind an untouched one, name a tool", () => {
  const rows: {
    name: string;
    harnesses: Choice["harnesses"];
    defaults: HarnessId[];
    allowed: boolean;
  }[] = [
    {
      name: "untouched, no default tool",
      harnesses: null,
      defaults: [],
      allowed: false,
    },
    {
      name: "untouched, one default tool",
      harnesses: null,
      defaults: ["claude"],
      allowed: true,
    },
    {
      name: "emptied by hand",
      harnesses: [],
      defaults: ["claude"],
      allowed: false,
    },
    {
      name: "a real selection",
      harnesses: ["claude"],
      defaults: [],
      allowed: true,
    },
  ];
  expect(rows).toHaveLength(4);
  for (const row of rows) {
    expect(
      isInstallable(
        { harnesses: row.harnesses, method: null, optional: [] },
        row.defaults,
      ),
      row.name,
    ).toBe(row.allowed);
  }
});
