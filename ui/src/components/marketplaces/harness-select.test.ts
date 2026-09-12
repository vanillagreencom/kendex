import { expect, it } from "vitest";
import type { HarnessId } from "@/bindings";
import { type Choice, isInstallable } from "./harness-select";

it("installs only where the choice, or the machine behind an untouched one, names a tool", () => {
  const rows: {
    name: string;
    harnesses: Choice["harnesses"];
    detected: HarnessId[];
    allowed: boolean;
  }[] = [
    {
      name: "untouched, nothing on this machine",
      harnesses: null,
      detected: [],
      allowed: false,
    },
    {
      name: "untouched, one tool on this machine",
      harnesses: null,
      detected: ["claude"],
      allowed: true,
    },
    {
      name: "emptied by hand",
      harnesses: [],
      detected: ["claude"],
      allowed: false,
    },
    {
      name: "a real selection",
      harnesses: ["claude"],
      detected: [],
      allowed: true,
    },
  ];
  expect(rows).toHaveLength(4);
  for (const row of rows) {
    expect(
      isInstallable(
        { harnesses: row.harnesses, method: null, optional: [] },
        row.detected,
      ),
      row.name,
    ).toBe(row.allowed);
  }
});
