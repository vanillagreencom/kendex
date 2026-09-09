import { describe, expect, it, vi } from "vitest";
import type { ScanWarning, UpdateRow } from "@/bindings";
import { EDITED_ATTENTION_ACTION, UPDATES_ATTENTION_DETAIL } from "@/lib/copy";
import { SEE_PROBLEMS_LABEL } from "@/lib/copy-marketplaces";
import { unreadablePlacesLabel } from "@/lib/copy-updates";
import { type AttentionSource, attentionRows } from "./attention-rows";

const HYPR = { scope: "project", root: "/work/hyprtrade" } as const;
const VG = { scope: "project", root: "/work/vg" } as const;

const edited = (name: string, scope: UpdateRow["scope"]): UpdateRow =>
  ({
    kind: "skill",
    name,
    scope,
    blockedByLocalEdit: true,
    editedHarnesses: ["claude"],
  }) as unknown as UpdateRow;

const warning = (
  problem: ScanWarning["problem"],
  standing: ScanWarning["standing"] = "actionable",
): ScanWarning => ({
  harness: "antigravity",
  kind: "mcp-server",
  path: "/h/.gemini/config/mcp_config.json",
  problem,
  standing,
});

const source = (over: Partial<AttentionSource>): AttentionSource => ({
  editedPackages: [],
  result: { harnesses: [], items: [], missingProjects: [], warnings: [] },
  updatesError: null,
  auditError: null,
  unreadable: [],
  onProjects: vi.fn(),
  onProblems: vi.fn(),
  onUpdates: vi.fn(),
  onEditedPackages: vi.fn(),
  onPackage: vi.fn(),
  onAuditRetry: vi.fn(),
  ...over,
});

const row = (rows: ReturnType<typeof attentionRows>, key: string) => {
  const found = rows.find((row) => row.key === key);
  expect(found, key).toBeDefined();
  return found as NonNullable<typeof found>;
};

// The row names the packages and where, says what "edited" is and what
// the two ways out are, and its link lands on those packages alone.
describe("the edited packages row", () => {
  it("names each package by place and lands on the edited packages only", () => {
    const onEditedPackages = vi.fn();
    const onPackage = vi.fn();
    const rows = attentionRows(
      source({
        editedPackages: [
          edited("commit-guards", HYPR),
          edited("second-opinion", HYPR),
          edited("worktree", HYPR),
          edited("gh", VG),
        ],
        onEditedPackages,
        onPackage,
      }),
    );
    const found = row(rows, "edited");
    expect(found.title).toBe("4 installed packages were edited on disk");
    expect(found.detail).toContain(
      "commit-guards, second-opinion and worktree in hyprtrade; gh in vg.",
    );
    expect(found.detail).toContain("no longer matches its source");
    expect(found.detail).toContain("Keep each as your own copy, or discard");
    expect(found.action?.label).toBe(EDITED_ATTENTION_ACTION);
    found.action?.onClick();
    expect(onEditedPackages).toHaveBeenCalledTimes(1);
    expect(onPackage).not.toHaveBeenCalled();
  });

  it("opens the one package's own page when there is one", () => {
    const onEditedPackages = vi.fn();
    const onPackage = vi.fn();
    const only = edited("gh", VG);
    const rows = attentionRows(
      source({ editedPackages: [only], onEditedPackages, onPackage }),
    );
    const found = row(rows, "edited");
    expect(found.title).toBe("1 installed package was edited on disk");
    expect(found.action?.label).toBe("gh");
    found.action?.onClick();
    expect(onPackage).toHaveBeenCalledWith(only);
    expect(onEditedPackages).not.toHaveBeenCalled();
  });

  it("tells two same-named projects apart by their path", () => {
    const rows = attentionRows(
      source({
        editedPackages: [
          edited("gh", VG),
          edited("dev", { scope: "project", root: "/other/vg" }),
        ],
      }),
    );
    expect(row(rows, "edited").detail).toContain(
      "gh in /work/vg; dev in /other/vg.",
    );
  });

  it("is absent with nothing edited", () => {
    expect(attentionRows(source({})).some((r) => r.key === "edited")).toBe(
      false,
    );
  });
});

// One row per file the scan could not read. Each names the tool, the
// shape of the problem, the path and the remedy, and lands on Problems,
// which carries the same file with its buttons.
describe("the unreadable file rows", () => {
  const rows: [ScanWarning["problem"], string, string][] = [
    [
      { kind: "empty-file" },
      "Antigravity's MCP servers file is empty",
      "Delete it, or put {} in it, then scan again.",
    ],
    [
      { kind: "invalid-json", message: "expected `,` at line 3 column 2" },
      "Antigravity's MCP servers file isn't valid JSON",
      "Fix it where the parser stopped: expected `,` at line 3 column 2. Then scan again.",
    ],
    [
      { kind: "invalid-toml", message: "expected `]` at line 1" },
      "Antigravity's MCP servers file isn't valid TOML",
      "Fix it where the parser stopped: expected `]` at line 1. Then scan again.",
    ],
    [
      { kind: "unreadable", message: "Permission denied (os error 13)" },
      "Antigravity's MCP servers file can't be read",
      "kendex couldn't open it: Permission denied (os error 13). Check its permissions, then scan again.",
    ],
    [
      {
        kind: "unknown-tag",
        message: "`tests` is not a tag; did you mean `testing`?",
      },
      "A tag in Antigravity's MCP servers file isn't one kendex knows",
      "`tests` is not a tag; did you mean `testing`? Fix the tags line, then scan again.",
    ],
  ];

  it("gives each unreadable-file problem its own explanation and destination", () => {
    expect(rows).toHaveLength(5);
    for (const [problem, title, remedy] of rows) {
      const onProblems = vi.fn();
      const found = row(
        attentionRows(
          source({
            result: {
              harnesses: [],
              items: [],
              missingProjects: [],
              warnings: [warning(problem)],
            },
            onProblems,
          }),
        ),
        "unreadable-file:/h/.gemini/config/mcp_config.json",
      );
      expect(found.title).toBe(title);
      expect(found.detail).toBe(
        `/h/.gemini/config/mcp_config.json — ${remedy}`,
      );
      expect(found.action?.label).toBe(SEE_PROBLEMS_LABEL);
      found.action?.onClick();
      expect(onProblems).toHaveBeenCalledTimes(1);
    }
  });

  it("leaves a file core marked as information off Home entirely", () => {
    const rows = attentionRows(
      source({
        result: {
          harnesses: [],
          items: [],
          missingProjects: [],
          warnings: [warning({ kind: "empty-file" }, "unused-empty-container")],
        },
      }),
    );
    expect(rows.filter((r) => r.key.startsWith("unreadable-file:"))).toEqual(
      [],
    );
  });

  it("gives every file its own row rather than one row with a count", () => {
    const first = warning({ kind: "empty-file" });
    const second = { ...first, path: "/h/.claude/settings.json" };
    const rows = attentionRows(
      source({
        result: {
          harnesses: [],
          items: [],
          missingProjects: [],
          warnings: [first, second],
        },
      }),
    );
    expect(
      rows.filter((r) => r.key.startsWith("unreadable-file:")),
    ).toHaveLength(2);
    expect(rows.some((r) => r.key === "warnings")).toBe(false);
  });
});

// The rows that stand as they are, pinned so a rewording that drops the
// remedy is caught: what to do is part of each.
describe("the other rows say what to do", () => {
  it("sends a failed update check back to Updates to check again", () => {
    const found = row(
      attentionRows(source({ updatesError: "no network" })),
      "updates-unchecked",
    );
    expect(found.detail).toBe(UPDATES_ATTENTION_DETAIL);
    expect(UPDATES_ATTENTION_DETAIL).toContain("Check again from Updates");
    expect(found.action?.label).toBe("Updates");
  });

  it("says a place's install record can't be read and where the reason is", () => {
    const found = row(
      attentionRows(
        source({ unreadable: [{ scope: HYPR, message: "newer schema" }] }),
      ),
      "updates-unreadable",
    );
    expect(found.detail).toBe(unreadablePlacesLabel(["hyprtrade"]));
    expect(found.detail).toContain(
      "can't read the install record for hyprtrade",
    );
    expect(found.action?.label).toBe(SEE_PROBLEMS_LABEL);
  });
});
