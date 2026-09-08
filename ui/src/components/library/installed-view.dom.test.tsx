// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ObservedItem, Scope } from "@/bindings";
import { InstalledView } from "@/components/library/installed-view";
import {
  READ_LANDED,
  READ_PENDING,
  type ReadState,
  readFailed,
} from "@/lib/read-state";
import { useEditorStore } from "@/stores/editor";
import { NO_FILTERS, useLibraryViewStore } from "@/stores/library-view";
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

const customizedText = (host: HTMLElement) =>
  [...host.querySelectorAll("tbody tr")]
    .map((row) => row.textContent ?? "")
    .filter((text) => text.includes("Customized"));

// The list says nothing about customization. A package customized in two
// places renders no "Customized in" line in any state — the line used to
// appear on hover through a CSS class, so the control is that no element
// carries the words at all — no legend above the table, and a kind icon
// in the same muted colour as every other row's. The package page's
// header is where the fact is said (package-header.test.tsx).
describe("a customized package in the Library list", () => {
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
    useLibraryViewStore.setState({ ...NO_FILTERS });
    useNavStore.setState({ libraryScope: "all", search: "" });
  });

  it("carries no mark, no legend and no customized colour", () => {
    const host = mount(<InstalledView />);
    expect(host.querySelectorAll("tbody tr")).toHaveLength(1);
    expect(customizedText(host)).toEqual([]);
    expect(host.textContent).not.toContain("Customized");
    expect(host.textContent).not.toContain("As the author wrote it");
    expect(host.querySelector(".text-customized")).toBeNull();
    expect(host.querySelector("tbody svg")?.getAttribute("class")).toContain(
      "text-muted-foreground",
    );
  });

  // The Where filter still decides which rows are on screen.
  it("still narrows the table to the place asked for", () => {
    useNavStore.setState({ libraryScope: { project: "/work/vg" }, search: "" });
    const host = mount(<InstalledView />);
    expect(host.querySelectorAll("tbody tr")).toHaveLength(1);
  });
});

// Home's edited row lands here narrowed to the packages it counted: the
// facet reads the same update rows, so a package edited on disk is on
// the page and one that is not is off it.
describe("the Library narrowed to packages edited on disk", () => {
  const other = {
    ...installed(VG),
    name: "orch",
    path: "/work/vg/.claude/skills/orch",
  };
  // orch has a row too, unedited: the facet must turn on the edit flag,
  // not on whether the updates read spoke about the package at all.
  const rows = [
    {
      kind: "skill",
      name: "gh",
      scope: VG,
      blockedByLocalEdit: true,
      editedHarnesses: ["claude"],
    },
    {
      kind: "skill",
      name: "orch",
      scope: VG,
      blockedByLocalEdit: false,
      editedHarnesses: [],
    },
  ];

  beforeEach(() => {
    vi.spyOn(useProvenanceStore.getState(), "load").mockResolvedValue();
    vi.spyOn(useEditorStore.getState(), "loadAll").mockResolvedValue();
    useEditorStore.setState({ saved: {} });
    useUpdatesStore.setState({ rows: rows as never, read: READ_LANDED });
    useScanStore.setState({
      result: {
        harnesses: [],
        items: [installed(VG), other],
        missingProjects: [],
        warnings: [],
      } as never,
    });
    useNavStore.setState({ libraryScope: "all", search: "" });
  });

  const names = (host: HTMLElement) =>
    [...host.querySelectorAll("tbody tr td:first-child")].map((cell) =>
      cell.querySelector("button")?.textContent?.trim(),
    );

  // Shaped input over one surface: what the updates read has said decides
  // whether the facet can answer. Landed and failed-with-rows are known
  // (Home draws its edited row from those rows); pending and a failed
  // first read that kept nothing have counted nothing, so the table holds
  // its skeleton rather than claiming no package is edited.
  const reads: [string, ReadState, unknown[], string[], boolean][] = [
    ["landed", READ_LANDED, rows, ["gh"], false],
    ["pending", READ_PENDING, [], [], true],
    ["failed with rows kept", readFailed("no network"), rows, ["gh"], false],
    ["failed with nothing kept", readFailed("no network"), [], [], true],
  ];

  it("answers for every known and unknown edited-package read", () => {
    expect(reads).toHaveLength(4);
    for (const [name, read, kept, expected, skeleton] of reads) {
      useUpdatesStore.setState({ rows: kept as never, read });
      useLibraryViewStore.setState({ ...NO_FILTERS, edited: "edited" });
      const host = mount(<InstalledView />);
      expect(
        names(host).filter((name) => name !== undefined),
        name,
      ).toEqual(expected);
      expect(host.querySelector('[data-slot="skeleton"]') !== null).toBe(
        skeleton,
      );
    }
  });

  it("shows every package when the facet is off", () => {
    useLibraryViewStore.setState({ ...NO_FILTERS });
    expect(names(mount(<InstalledView />))).toEqual(["gh", "orch"]);
  });
});
