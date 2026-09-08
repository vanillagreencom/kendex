import { describe, expect, it } from "vitest";
import { NO_REASON_GIVEN, settled } from "./settled";

describe("settled", () => {
  it("keeps each returned or rejected failure value", async () => {
    const rows: {
      name: string;
      read: () => Promise<{ status: "error"; error: string }>;
      expected: { status: "error"; error: string };
    }[] = [
      {
        name: "returned refusal",
        read: () => Promise.resolve({ status: "error", error: "refused" }),
        expected: { status: "error", error: "refused" },
      },
      {
        name: "rejected Error",
        read: () => Promise.reject(new Error("ipc down")),
        expected: { status: "error", error: "ipc down" },
      },
      {
        name: "empty Error",
        read: () => Promise.reject(new Error()),
        expected: { status: "error", error: NO_REASON_GIVEN },
      },
      {
        name: "empty rejected string",
        read: () => Promise.reject(""),
        expected: { status: "error", error: NO_REASON_GIVEN },
      },
      {
        name: "empty returned refusal",
        read: () => Promise.resolve({ status: "error", error: "" }),
        expected: { status: "error", error: NO_REASON_GIVEN },
      },
    ];

    expect(rows.length, "settled failure table is empty").toBeGreaterThan(0);
    for (const row of rows) {
      await expect(settled(row.read()), row.name).resolves.toEqual(
        row.expected,
      );
    }
  });
});
