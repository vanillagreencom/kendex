import { describe, expect, it } from "vitest";
import type { WriteRefused } from "@/bindings";
import { refusalKind, refusalWords } from "./refusal";

describe("refusal values", () => {
  it("keeps the kind and words of each refusal shape", () => {
    const rows: {
      name: string;
      refusal: WriteRefused | string;
      expected: { kind: string | null; words: string | null };
    }[] = [
      {
        name: "failed",
        refusal: { kind: "failed", message: "disk is full" },
        expected: { kind: "failed", words: "disk is full" },
      },
      {
        name: "stale",
        refusal: { kind: "stale" },
        expected: { kind: "stale", words: null },
      },
      {
        name: "transport string",
        refusal: "the channel is gone",
        expected: { kind: null, words: "the channel is gone" },
      },
    ];

    expect(rows.length, "refusal shape table is empty").toBeGreaterThan(0);
    for (const row of rows) {
      expect(
        { kind: refusalKind(row.refusal), words: refusalWords(row.refusal) },
        row.name,
      ).toEqual(row.expected);
    }
  });
});
