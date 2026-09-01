import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { updateRow } from "@/components/updates-test-rows";
import { EditedNotice } from "./fork-notice";

// Static rendering reads a zustand store's initial snapshot, so the store
// hook is wrapped to let each test seed the rows it needs.
const stub = vi.hoisted(() => ({
  rows: [] as unknown[],
  settling: [] as { scope: { scope: string; root?: string } }[],
  busy: false,
  checking: false,
}));
vi.mock("@/stores/updates", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/updates")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    // A row to act on implies a read that landed; without that every
    // control here reads as held and the gates under test say nothing.
    const state = {
      ...mod.useUpdatesStore.getState(),
      rows: stub.rows,
      pendingFollows: stub.settling,
      read: { status: "landed", error: null },
      busy: stub.busy,
      checking: stub.checking,
    };
    return selector ? selector(state) : state;
  };
  return { ...mod, useUpdatesStore: Object.assign(hook, mod.useUpdatesStore) };
});

const render = (
  rows: UpdateRow[],
  settling: { scope: { scope: string; root?: string } }[] = [],
  running: { busy?: boolean; checking?: boolean } = {},
) => {
  stub.rows = rows;
  stub.settling = settling;
  stub.busy = running.busy ?? false;
  stub.checking = running.checking ?? false;
  return renderToStaticMarkup(
    <EditedNotice
      scope={{ scope: "global" }}
      kind="agent"
      name="rev"
      alreadyForked={false}
      onViewChanges={() => {}}
      onResolved={() => {}}
    />,
  );
};

const edited = (extra: Partial<UpdateRow>) =>
  updateRow("rev", null, { kind: "agent", blockedByLocalEdit: true, ...extra });

describe("package page edited notice", () => {
  it("shows nothing without an edited row for this package", () => {
    expect(render([updateRow("rev", null, { kind: "agent" })])).toBe("");
  });

  it("offers the fork only through the rendering the engine can take", () => {
    const html = render([
      edited({ editedHarnesses: ["claude"], forkableHarness: "claude" }),
    ]);
    expect(html).toContain(">Keep as my own<");
    expect(html).toContain(">Discard edits…<");
  });

  it("names the edited tools and offers only a full discard for several", () => {
    const html = render([
      edited({
        editedHarnesses: ["claude", "opencode"],
        forkableHarness: null,
      }),
    ]);
    expect(html).not.toContain(">Keep as my own<");
    expect(html).toContain("Edited in Claude Code and OpenCode.");
    expect(html).toContain("would drop the other edits");
    expect(html).toContain(">Discard all edits…<");
    expect(html).toContain(">View changes in Claude Code<");
    expect(html).toContain(">View changes in OpenCode<");
    expect(html).not.toContain(">View changes<");
  });

  it("says why a lone non-forkable rendering cannot become a fork", () => {
    const html = render([
      edited({ editedHarnesses: ["opencode"], forkableHarness: null }),
    ]);
    expect(html).not.toContain(">Keep as my own<");
    // Static markup escapes the apostrophes.
    expect(html).toContain(
      "OpenCode&#x27;s copy can&#x27;t be kept as your own.",
    );
  });

  it("keeps Discard edits for an owner-held derived package", () => {
    const html = render([
      edited({
        editedHarnesses: ["claude"],
        forkableHarness: null,
        derived: true,
        pinned: true,
        canDiscard: true,
        canTakeLatest: false,
      }),
    ]);
    expect(html).not.toContain(">Keep as my own<");
    expect(html).toContain(">Discard edits…<");
  });

  it("hides the discard when the source has nothing to put in its place", () => {
    const html = render([
      edited({
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
        canDiscard: false,
        canTakeLatest: false,
      }),
    ]);
    expect(html).not.toContain(">Discard edits…<");
    expect(html).toContain(">View changes<");
  });

  // Keeping the files as a fork copies what is on disk and reads nothing
  // off the row, so what the row's own standing says about it decides
  // nothing: a flip settling in its scope leaves it live, and so does a
  // check that failed. What bars it is that it commits — `running()`, a
  // check out or a write out, which is the pair varied here.
  it("holds Keep as my own for the work already running, and nothing else", () => {
    const rows = [
      edited({ editedHarnesses: ["claude"], forkableHarness: "claude" }),
    ];
    const forkHeld = (html: string): boolean => {
      const tag = html.match(/<button[^>]*>Keep as my own<\/button>/)?.[0];
      if (!tag) throw new Error("no Keep as my own button");
      return tag.includes('disabled=""');
    };
    expect(forkHeld(render(rows))).toBe(false);
    expect(forkHeld(render(rows, [], { busy: true }))).toBe(true);
    expect(forkHeld(render(rows, [], { checking: true }))).toBe(true);
    // The two the discard beside it waits for, which this one does not.
    expect(forkHeld(render(rows, [{ scope: { scope: "global" } }]))).toBe(
      false,
    );
  });

  // Discarding applies the row's latest commit off a `pinned` a settling
  // flip may have painted, so takeNewVersion refuses for that scope. The
  // button says so rather than inviting a click that only errors.
  it("holds Discard edits while a flip settles in this scope", () => {
    const rows = [
      edited({ editedHarnesses: ["claude"], forkableHarness: "claude" }),
    ];
    const discardHeld = (html: string): boolean => {
      const tag = html.match(/<button[^>]*>Discard edits…<\/button>/)?.[0];
      if (!tag) throw new Error("no Discard edits button");
      return tag.includes('disabled=""');
    };
    expect(discardHeld(render(rows))).toBe(false);
    expect(discardHeld(render(rows, [{ scope: { scope: "global" } }]))).toBe(
      true,
    );
    expect(
      discardHeld(
        render(rows, [{ scope: { scope: "project", root: "/home/me/app" } }]),
      ),
    ).toBe(false);
    // A check about to replace the rows bars it for the same reason the
    // flip does: the `latest` it would apply is not confirmed.
    expect(discardHeld(render(rows, [], { checking: true }))).toBe(true);
  });
});
