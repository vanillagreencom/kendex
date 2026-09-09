// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it } from "vitest";
import type { RecentGroup } from "@/lib/derive";
import { useNavStore } from "@/stores/nav";
import { mount } from "@/test/dom";
import { RecentActivity } from "./recent-activity";

const AT = Date.UTC(2024, 0, 2, 3, 4, 5) / 1000;
const SCOPE = { scope: "project" as const, root: "/work/vg" };

const group = (installed: boolean): RecentGroup => ({
  key: "skill:gh",
  kind: "skill",
  name: "gh",
  description: null,
  installations: installed
    ? ([
        {
          kind: "skill",
          name: "gh",
          scope: SCOPE,
          harness: "claude",
          path: "/work/vg/.claude/skills/gh",
          fileState: "file",
          enabled: true,
          origin: null,
          description: null,
          tags: [],
        },
      ] as never)
    : [],
  harnesses: ["claude"],
  tags: [],
  shared: false,
  modifiedAt: AT,
});

beforeEach(() => {
  useNavStore.setState({ page: "home", packageRef: null });
});

// A row names one package, so it opens that package — not a Library
// narrowed to everything of the same kind, which is a different place.
describe("a row on Home's recent list", () => {
  it("opens the package it names, at the place it sits in", async () => {
    const host = mount(<RecentActivity groups={[group(true)]} />);
    const row = host.querySelector("button");
    if (!row) throw new Error("no row rendered");
    await userEvent.click(row);
    const nav = useNavStore.getState();
    expect(nav.page).toBe("package");
    expect(nav.packageRef).toEqual({ kind: "skill", name: "gh", scope: SCOPE });
  });

  // The control: with no installation there is no place to open the
  // package at, and a page about a place that does not have it would show
  // nothing. The row stays where it is.
  it("goes nowhere for a group with no installation behind it", async () => {
    const host = mount(<RecentActivity groups={[group(false)]} />);
    const row = host.querySelector("button");
    if (!row) throw new Error("no row rendered");
    await userEvent.click(row);
    expect(useNavStore.getState().page).toBe("home");
  });
});
