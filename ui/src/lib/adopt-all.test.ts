import { describe, expect, it } from "vitest";
import type { DriftRow, HarnessId } from "@/bindings";
import { adoptAll, type SharedLink } from "./adopt-all";
import type { MergedDriftRow } from "./drift-merge";

const group = (name: string, harnesses: HarnessId[]): MergedDriftRow => ({
  kind: "skill",
  name,
  state: "unmanaged",
  installations: harnesses.map((harness) => ({
    kind: "skill",
    name,
    harness,
    scope: { scope: "project", root: "/w/app" },
    state: "unmanaged",
    detail: `/w/app/${harness}/${name}`,
  })) as DriftRow[],
});

const record = (answer: (n: number) => boolean = () => true) => {
  const calls: { name: string; harnesses: HarnessId[]; quiet?: boolean }[] = [];
  const adopt = async (
    _kind: DriftRow["kind"],
    name: string,
    harnesses: HarnessId[],
    quiet?: boolean,
  ) => {
    calls.push({ name, harnesses, quiet });
    return answer(calls.length);
  };
  return { calls, adopt };
};

describe("starting to manage a page of items", () => {
  it("takes an item's tools in one call, and says one line for the run", async () => {
    const { calls, adopt } = record();

    await adoptAll(
      [group("deploy", ["claude", "codex"]), group("lint", ["claude"])],
      () => null,
      adopt,
    );

    expect(calls).toEqual([
      { name: "deploy", harnesses: ["claude", "codex"], quiet: false },
      { name: "lint", harnesses: ["claude"], quiet: true },
    ]);
  });

  // After one has failed the rest are answering against a page that is now
  // wrong, and the run would still finish looking like it worked.
  it("stops at the first item that did not work", async () => {
    const { calls, adopt } = record((n) => n < 2);

    await adoptAll(
      [group("a", ["claude"]), group("b", ["claude"]), group("c", ["claude"])],
      () => null,
      adopt,
    );

    expect(calls.map((call) => call.name)).toEqual(["a", "b"]);
  });

  it("returns a deferred folder only when the remaining adoption succeeds", async () => {
    const rows = [
      { name: "shared folder deferred after success", succeeds: true },
      { name: "shared folder dropped after failure", succeeds: false },
    ];
    expect(
      rows.length,
      "shared adoption outcome table is empty",
    ).toBeGreaterThan(0);
    for (const row of rows) {
      const { calls, adopt } = record(() => row.succeeds);
      const browser = group("browser", ["claude"]);
      const link: SharedLink = {
        group: browser,
        harness: "claude",
        target: "/w/shared",
        tools: ["claude"],
      };
      const shared = await adoptAll(
        [browser, group("deploy", ["claude"])],
        (g) => (g.name === "browser" ? link : null),
        adopt,
      );
      expect(
        {
          sameLink: shared === link,
          shared,
          calls: calls.map((call) => call.name),
        },
        row.name,
      ).toEqual({
        sameLink: row.succeeds,
        shared: row.succeeds ? link : null,
        calls: ["deploy"],
      });
    }
  });
});
