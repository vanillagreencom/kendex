// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { PackageDiff, UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { updateRow as row } from "@/components/updates-test-rows";
import {
  UPDATE_DIFF_NO_VERSIONS,
  UPDATE_REVIEW_BODY,
  UPDATE_REVIEW_CONFIRM,
  updateReviewOneTitle,
  updateReviewSkipped,
} from "@/lib/copy-updates";
import { mount, settle } from "@/test/dom";
import { UpdateReviewDialog } from "./update-review-dialog";

vi.mock("@/bindings", () => ({ commands: { packageDiff: vi.fn() } }));

const DIFF: PackageDiff = {
  files: [
    {
      path: "SKILL.md",
      status: "modified",
      additions: 2,
      deletions: 1,
      lossy: false,
      hunks: [
        {
          header: "@@ -1 +1,2 @@",
          lines: [
            { kind: "context", text: "# gh", oldNo: 1, newNo: 1 },
            { kind: "add", text: "a new line", oldNo: null, newNo: 2 },
          ],
        },
      ],
    },
  ],
  totalAdditions: 2,
  totalDeletions: 1,
  truncated: false,
};

const edited = (name: string, root: string | null): UpdateRow =>
  row(name, root, {
    blockedByLocalEdit: true,
    editedHarnesses: ["claude"],
  });

const open = (rows: UpdateRow[], onConfirm = vi.fn()) => {
  const host = mount(
    <UpdateReviewDialog
      rows={rows}
      place={null}
      open
      onOpenChange={() => {}}
      busy={false}
      onConfirm={onConfirm}
    />,
  );
  return { host, onConfirm };
};

// The dialog is portalled, so what a reader sees is the whole document.
const shown = () => document.body.textContent ?? "";
const button = (label: string): HTMLButtonElement => {
  const found = [...document.querySelectorAll("button")].find(
    (b) => b.textContent === label,
  );
  if (!found) throw new Error(`no ${label} button`);
  return found;
};

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(commands.packageDiff).mockResolvedValue({
    status: "ok",
    data: DIFF,
  });
});

describe("the update review", () => {
  it("shows what changes before anything is written", async () => {
    const { onConfirm } = open([row("gh", null)]);
    await settle();

    expect(commands.packageDiff).toHaveBeenCalledWith(
      { scope: "global" },
      "skill",
      "gh",
      { at: "commit", commit: "1111111111" },
      { at: "commit", commit: "2222222222" },
      null,
    );
    expect(shown()).toContain("SKILL.md");
    expect(shown()).toContain("a new line");
    expect(shown()).toContain(UPDATE_REVIEW_BODY);
    expect(shown()).toContain(updateReviewOneTitle("gh", "User level"));
    // Nothing has been asked of the engine but the comparison.
    expect(onConfirm).not.toHaveBeenCalled();

    await userEvent.click(button(UPDATE_REVIEW_CONFIRM));
    expect(onConfirm).toHaveBeenCalledTimes(1);
  });

  // A list is a list to pick from first: reading four packages' diffs to
  // draw a dialog nobody has scrolled is work nobody asked for.
  it("opens one package's changes and leaves several folded", async () => {
    open([row("gh", null), row("dev", null)]);
    await settle();

    expect(commands.packageDiff).not.toHaveBeenCalled();
    expect(shown()).toContain("gh in User level");
    expect(shown()).toContain("dev in User level");

    await userEvent.click(button("gh in User level"));
    await settle();
    expect(commands.packageDiff).toHaveBeenCalledTimes(1);
    expect(shown()).toContain("SKILL.md");
  });

  // The offer is what this dialog can act on, and what it cannot is
  // counted rather than silently dropped.
  it("hands back only the places an update can be taken in", async () => {
    const { onConfirm } = open([
      row("gh", null),
      edited("dev", null),
      row("orch", null, { derived: true, pinned: true }),
    ]);
    await settle();

    expect(shown()).toContain(updateReviewSkipped(2));
    expect(shown()).not.toContain("dev in User level");

    await userEvent.click(button(UPDATE_REVIEW_CONFIRM));
    expect(onConfirm).toHaveBeenCalledTimes(1);
    expect(onConfirm.mock.calls[0]?.[0].map((r: UpdateRow) => r.name)).toEqual([
      "gh",
    ]);
  });

  // The comparison is the reader's help, not the update's premise: a place
  // whose revisions the standing does not carry still takes its update.
  it("says why there is no comparison and still offers the update", async () => {
    open([row("gh", null, { current: null })]);
    await settle();

    expect(commands.packageDiff).not.toHaveBeenCalled();
    expect(shown()).toContain(UPDATE_DIFF_NO_VERSIONS);
    expect(button(UPDATE_REVIEW_CONFIRM).disabled).toBe(false);
  });

  it("says a failed comparison instead of an empty panel", async () => {
    vi.mocked(commands.packageDiff).mockResolvedValue({
      status: "error",
      error: "the mirror is gone",
    });
    open([row("gh", null)]);
    await settle();

    expect(shown()).toContain("the mirror is gone");
    expect(button(UPDATE_REVIEW_CONFIRM).disabled).toBe(false);
  });
});
