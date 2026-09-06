// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ObservedItem, ScanResult, Scope } from "@/bindings";
import { InstalledView } from "@/components/library/installed-view";
import { kindLabel } from "@/lib/labels";
import { READ_LANDED } from "@/lib/read-state";
import { useEditorStore } from "@/stores/editor";
import { useLibraryViewStore } from "@/stores/library-view";
import { useNavStore } from "@/stores/nav";
import { useProvenanceStore } from "@/stores/provenance";
import { useScanStore } from "@/stores/scan";
import { useSettingsStore } from "@/stores/settings";
import { useUpdatesStore } from "@/stores/updates";
import { mount } from "@/test/dom";
import { HarnessList } from "./harness-list";

const ACME: Scope = { scope: "project", root: "/work/acme" };

const installed = (overrides: Partial<ObservedItem>): ObservedItem => ({
  kind: "skill",
  name: "deploy",
  harness: "claude",
  scope: { scope: "global" },
  path: "/h/.claude/skills/deploy",
  fileState: { state: "dir" },
  enabled: true,
  origin: null,
  description: null,
  tags: [],
  modifiedAt: null,
  vendor: null,
  ...overrides,
});

// Claude carries two skills over three installations: one of them lives
// globally and in a project both. Counting installations puts 3 on the badge
// over a table of 2 rows, which is what these cases are here to catch.
const scanned: ScanResult = {
  harnesses: [
    { harness: "claude", root: "/h/.claude", version: null },
    { harness: "codex", root: "/h/.codex", version: null },
  ],
  items: [
    installed({}),
    installed({ scope: ACME, path: "/work/acme/.claude/skills/deploy" }),
    installed({ name: "lint", path: "/h/.claude/skills/lint" }),
    installed({ harness: "codex", path: "/h/.codex/skills/deploy" }),
  ],
  missingProjects: [],
  warnings: [],
};

// Read off the badge's own wording rather than a second copy of it here, so
// a relabelled kind fails as a missing badge rather than passing vacuously.
const SKILL_BADGE = new RegExp(
  `^(\\d+) (${kindLabel("skill", 1)}|${kindLabel("skill", 2)})$`,
);

/** The skills badge on the row for one harness. */
function skillBadge(host: HTMLElement, harness: string): HTMLButtonElement {
  const row = [...host.querySelectorAll<HTMLElement>("div.group")].find((el) =>
    el.textContent?.startsWith(harness),
  );
  if (!row) throw new Error(`no row for ${harness}`);
  const badge = [...row.querySelectorAll<HTMLButtonElement>("button")].find(
    (b) => SKILL_BADGE.test(b.textContent ?? ""),
  );
  if (!badge) throw new Error(`no skills badge on the ${harness} row`);
  return badge;
}

const badgeCount = (host: HTMLElement, harness: string): number =>
  Number(SKILL_BADGE.exec(skillBadge(host, harness).textContent ?? "")?.[1]);

/** The rows the Library actually renders for the view the click handed it. */
const destinationRows = (): number =>
  mount(<InstalledView />).querySelectorAll("tbody tr").length;

beforeEach(() => {
  vi.spyOn(useProvenanceStore.getState(), "load").mockResolvedValue();
  vi.spyOn(useEditorStore.getState(), "loadAll").mockResolvedValue();
  useUpdatesStore.setState({ rows: [], read: READ_LANDED });
  useScanStore.setState({ scanning: false, result: scanned, error: null });
  useSettingsStore.setState({ settings: { projects: [] } as never });
  useNavStore.setState({
    page: "harnesses",
    libraryFilter: null,
    libraryScope: "all",
    search: "",
  });
  useLibraryViewStore.setState({
    kind: "any",
    harness: "any",
    tag: "any",
    from: "any",
  });
});

// A badge is a promise about the page behind it. The Library shows one row
// per package however many harnesses or places carry it, so a badge counting
// installations lands on a table shorter than the number just clicked.
describe("a harness row's kind badge", () => {
  it("shows the row count of the view its click opens", () => {
    const host = mount(<HarnessList />);
    const badge = badgeCount(host, "Claude Code");

    act(() => skillBadge(host, "Claude Code").click());
    expect(useNavStore.getState().libraryFilter).toEqual({
      harness: "claude",
      kind: "skill",
    });
    expect(badge).toBe(destinationRows());
  });

  // The must-fail control: three installations of two packages sit behind
  // the Claude row, so 3 is the pre-fix number this case rejects. Without
  // it the equality above would hold on any pair that moved together.
  it("counts packages rather than the installations behind them", () => {
    const host = mount(<HarnessList />);
    expect(badgeCount(host, "Claude Code")).toBe(2);
    expect(badgeCount(host, "Codex")).toBe(1);
  });
});
