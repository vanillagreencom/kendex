// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ObservedItem, Scope } from "@/bindings";
import { InstalledView } from "@/components/library/installed-view";
import { READ_LANDED } from "@/lib/read-state";
import { useEditorStore } from "@/stores/editor";
import { useLibraryViewStore } from "@/stores/library-view";
import { useNavStore } from "@/stores/nav";
import { useProvenanceStore } from "@/stores/provenance";
import { useScanStore } from "@/stores/scan";
import { useUpdatesStore } from "@/stores/updates";
import { mount } from "@/test/dom";

const VG: Scope = { scope: "project", root: "/work/vg" };
const HYPR: Scope = { scope: "project", root: "/work/hyprtrade" };

const installed = (scope: Scope): ObservedItem =>
  ({
    kind: "skill",
    name: "gh",
    scope,
    harness: "claude",
    path: `${scope.scope === "project" ? scope.root : ""}/.claude/skills/gh`,
    fileState: { state: "file" },
    enabled: true,
    origin: null,
    description: "about gh",
    tags: [],
    modifiedAt: null,
    vendor: null,
  }) as unknown as ObservedItem;

// Customized in both places.
const mine = { schema: 1, install: {}, "skill-instructions": { gh: "mine" } };

const markOf = (host: HTMLElement) =>
  [...host.querySelectorAll("tbody tr")]
    .map((row) => row.textContent ?? "")
    .find((text) => text.includes("Customized"));

// A row's mark answers for the package, so the Where filter may decide
// which rows are on screen and never what one of them says. Read from the
// filtered groups, this row said "Customized in vg" while the package's
// own page named both places — the contradiction the issue is about,
// arriving through the filter instead of through the header.
describe("the Library's mark under a Where filter", () => {
  beforeEach(() => {
    vi.spyOn(useProvenanceStore.getState(), "load").mockResolvedValue();
    vi.spyOn(useEditorStore.getState(), "loadAll").mockResolvedValue();
    useEditorStore.setState({
      saved: { "/work/vg": mine as never, "/work/hyprtrade": mine as never },
    });
    useUpdatesStore.setState({ rows: [], read: READ_LANDED });
    useScanStore.setState({
      result: {
        harnesses: [],
        items: [installed(VG), installed(HYPR)],
        missingProjects: [],
        warnings: [],
      } as never,
    });
    useLibraryViewStore.setState({
      kind: "any",
      harness: "any",
      tag: "any",
      from: "any",
    });
  });

  const shown = (scope: "all" | { project: string }) => {
    useNavStore.setState({ libraryScope: scope, search: "" });
    return markOf(mount(<InstalledView />));
  };

  it("says the same thing narrowed to one project as it does unnarrowed", () => {
    const everywhere = shown("all");
    expect(everywhere).toContain("2 of 2 projects");

    const narrowed = shown({ project: "/work/vg" });
    expect(narrowed).toContain("2 of 2 projects");
    expect(narrowed).toContain("Customized in vg and hyprtrade");
  });

  // The filter still decides which rows are on screen.
  it("still narrows the table to the place asked for", () => {
    useNavStore.setState({ libraryScope: { project: "/work/vg" }, search: "" });
    const host = mount(<InstalledView />);
    expect(host.querySelectorAll("tbody tr")).toHaveLength(1);
  });
});
