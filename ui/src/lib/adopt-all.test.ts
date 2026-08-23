import { describe, expect, it } from "vitest";
import type { DriftRow, HarnessId } from "@/bindings";
import type { SharedLink } from "@/lib/adopt-shared";
import { adoptAll } from "./adopt-all";
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

  // A folder read through shortcuts needs its own confirmation, so it is
  // handed back rather than taken with the rest.
  it("hands back the first shared folder instead of adopting it", async () => {
    const { calls, adopt } = record();
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

    expect(shared).toBe(link);
    expect(calls.map((call) => call.name)).toEqual(["deploy"]);
  });
});

describe("a shared folder read before something fails", () => {
  // Its confirmation would open against a page that is now wrong, so the
  // failure takes the deferred folder with it.
  it("is dropped rather than confirmed after the failure", async () => {
    const { calls, adopt } = record(() => false);
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

    expect(shared).toBeNull();
    expect(calls.map((call) => call.name)).toEqual(["deploy"]);
  });
});
