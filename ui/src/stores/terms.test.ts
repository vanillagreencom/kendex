import { describe, expect, it } from "vitest";
import type { TermsState } from "@/bindings";
import { acceptedSummary } from "./terms";

describe("what the About row says the terms record holds", () => {
  it("distinguishes an accepted record, an empty record and an unread record", () => {
    const rows: { name: string; state: TermsState | null; summary: string }[] =
      [
        {
          name: "accepted version and date",
          state: {
            ask: false,
            accepted: { version: 1, "accepted-at": "2026-09-06T10:11:12Z" },
          },
          summary: "version 1, accepted 2026-09-06",
        },
        {
          name: "read and empty",
          state: { ask: true, accepted: null },
          summary: "not accepted",
        },
        { name: "unread", state: null, summary: "…" },
      ];
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows)
      expect(acceptedSummary(row.state), row.name).toBe(row.summary);
  });
});
