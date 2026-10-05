// @vitest-environment jsdom
// The Details block draws which harnesses the package runs on from the
// record core answered, the same row the available package's facts column
// draws; what each shape of that answer reads as is the row's own test.
import { beforeEach, describe, expect, it } from "vitest";
import type { PackageMeta_Serialize } from "@/bindings";
import {
  SUPPORTED_HARNESSES_LABEL,
  SUPPORTED_UNKNOWN,
} from "@/lib/copy-library";
import type { ItemGroup } from "@/lib/derive";
import { harnessName } from "@/lib/labels";
import { useProvenanceStore } from "@/stores/provenance";
import { mount } from "@/test/dom";
import { observed } from "@/test/observed";
import { PackageMetaBlock } from "./package-meta";

const primary = observed({
  kind: "hook",
  name: "stop-row",
  harness: "claude",
  scope: { scope: "global" },
  path: "/h/.claude/hooks/stop-row.sh",
  fileState: { state: "file" },
  enabled: true,
  origin: null,
  summary: null,
  action: null,
  tags: [],
  modifiedAt: null,
  vendor: null,
});

const group: ItemGroup = {
  key: "hook:stop-row",
  package: { kind: "hook", name: "stop-row" },
  kind: "hook",
  name: "stop-row",
  summary: null,
  installations: [primary],
  harnesses: ["claude"],
  tags: [],
  shared: false,
  modifiedAt: null,
};

const META: PackageMeta_Serialize = {
  source: "cat",
  repo: "o/r",
  repoUrl: null,
  rev: null,
  current: null,
  installedAt: null,
  harnesses: ["claude"],
  enabled: true,
  fork: null,
  catalog: null,
  support: {
    state: "read",
    unsupported: [
      { tool: "pi", reason: "it has no Stop event" },
      { tool: "gemini", reason: null },
    ],
    advisory: ["opencode"],
    fallback: [{ tool: "codex", reason: "a watcher reads its pane" }],
  },
};

/** The value cell of the row labelled `label`, or null when none is drawn. */
const rowValue = (host: HTMLElement, label: string): Element | null =>
  [...host.querySelectorAll("dt")].find((dt) => dt.textContent === label)
    ?.nextElementSibling ?? null;

beforeEach(() => {
  // Read already: the block's own provenance read is not under test here.
  useProvenanceStore.setState({ rows: [], loaded: true });
});

describe("the harnesses an installed package runs on", () => {
  it("draws the record's unsupported, advisory and fallback harnesses", () => {
    const host = mount(
      <PackageMetaBlock group={group} primary={primary} meta={META} />,
    );

    const row = rowValue(host, SUPPORTED_HARNESSES_LABEL);
    if (!row) throw new Error("no supported harnesses row");
    const chips = [...row.querySelectorAll("button")].map((chip) =>
      chip.getAttribute("aria-label"),
    );
    expect(chips).toEqual(
      (["pi", "gemini", "opencode", "codex"] as const).map(harnessName),
    );
    expect(row.textContent).toContain("it has no Stop event");
    expect(row.textContent).toContain("a watcher reads its pane");
  });

  // A record whose hook header core could not read says so, with why, and
  // names no harness: neither every one nor none of them is known.
  it("draws the cause where the record's header could not be read", () => {
    const host = mount(
      <PackageMetaBlock
        group={group}
        primary={primary}
        meta={{
          ...META,
          support: { state: "unread", cause: "source 'cat' is disabled" },
        }}
      />,
    );

    const row = rowValue(host, SUPPORTED_HARNESSES_LABEL);
    if (!row) throw new Error("no supported harnesses row");
    expect(row.querySelectorAll("button")).toHaveLength(0);
    expect(row.textContent).toContain(SUPPORTED_UNKNOWN);
    expect(row.textContent).toContain("source 'cat' is disabled");
  });

  // With no record there is no answer to draw, and a row claiming every
  // harness would be a claim nothing made.
  it("draws no row without a record", () => {
    const host = mount(
      <PackageMetaBlock group={group} primary={primary} meta={null} />,
    );

    expect(rowValue(host, SUPPORTED_HARNESSES_LABEL)).toBeNull();
  });
});
