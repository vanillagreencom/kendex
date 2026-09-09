// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ObservedItem, ScanResult, Scope } from "@/bindings";
import { InstalledView } from "@/components/library/installed-view";
import { PLACE_COUNTING_LABEL, PLACE_UNCHECKED_LABEL } from "@/lib/copy";
import { kindLabel } from "@/lib/labels";
import { READ_LANDED, READ_PENDING, readFailed } from "@/lib/read-state";
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

/** The skills badge on the row for one harness, or null where the row draws
 *  none. One place finds it, so what a test says is missing is what another
 *  says is there. */
function findSkillBadge(
  host: HTMLElement,
  harness: string,
): HTMLButtonElement | null {
  const row = [...host.querySelectorAll<HTMLElement>("div.group")].find((el) =>
    el.textContent?.startsWith(harness),
  );
  if (!row) throw new Error(`no row for ${harness}`);
  return (
    [...row.querySelectorAll<HTMLButtonElement>("button")].find((b) =>
      SKILL_BADGE.test(b.textContent ?? ""),
    ) ?? null
  );
}

/** The skills badge on the row for one harness. */
function skillBadge(host: HTMLElement, harness: string): HTMLButtonElement {
  const badge = findSkillBadge(host, harness);
  if (!badge) throw new Error(`no skills badge on the ${harness} row`);
  return badge;
}

const badgeCount = (host: HTMLElement, harness: string): number =>
  Number(SKILL_BADGE.exec(skillBadge(host, harness).textContent ?? "")?.[1]);

/** The rows the Library actually renders for the view the click handed it. */
const destinationRows = (): number =>
  mount(<InstalledView />).querySelectorAll("tbody tr").length;

beforeEach(() => {
  vi.spyOn(useEditorStore.getState(), "loadAll").mockResolvedValue();
  // The join has answered and recorded nothing: these packages group as
  // the scan saw them, which is what the fixture means.
  useProvenanceStore.setState({ rows: [], loaded: true, read: READ_LANDED });
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
    expect(badge).toBe(2);
    expect(badgeCount(host, "Codex")).toBe(1);

    act(() => skillBadge(host, "Claude Code").click());
    expect(useNavStore.getState().libraryFilter).toEqual({
      harness: "claude",
      kind: "skill",
    });
    expect(badge).toBe(destinationRows());
  });
});

// A badge counts packages and its click opens the Library on the same
// narrowing. Until the read that says which installations are one package
// answers, there is no number: counted anyway, a hook installed for several
// tools reads as several entries under whichever kinds its files happen to
// be, and the click lands on a shorter, differently-kinded list.
describe("a harness row's badges before the identity read answers", () => {
  const rows = [
    {
      name: "still on its way",
      provenance: { rows: [], loaded: false, read: READ_PENDING },
      said: PLACE_COUNTING_LABEL,
      absent: PLACE_UNCHECKED_LABEL,
    },
    {
      name: "failed with nothing kept",
      provenance: { rows: [], loaded: false, read: readFailed("no lock") },
      said: PLACE_UNCHECKED_LABEL,
      absent: PLACE_COUNTING_LABEL,
    },
  ];

  it("says why there is no count, and which of the two it is", () => {
    expect(rows).toHaveLength(2);
    for (const row of rows) {
      useProvenanceStore.setState(row.provenance);
      const host = mount(<HarnessList />);
      expect(host.textContent, row.name).toContain(row.said);
      expect(host.textContent, row.name).not.toContain(row.absent);
      // No badge at all where a package count would be: not a count of
      // installations under a package's label, and not a zero either.
      expect(findSkillBadge(host, "Claude Code"), row.name).toBeNull();
    }
  });
});
