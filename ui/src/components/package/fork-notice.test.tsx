import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { updateRow } from "@/components/updates-test-rows";
import { EditedNotice } from "./fork-notice";

// Static rendering reads a zustand store's initial snapshot, so the store
// hook is wrapped to let each test seed the rows it needs.
const stub = vi.hoisted(() => ({
  rows: [] as unknown[],
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
  running: { busy?: boolean; checking?: boolean } = {},
) => {
  stub.rows = rows;
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
  it("shows only the actions available for each edited rendering", () => {
    const rows = [
      {
        name: "unedited",
        input: updateRow("rev", null, { kind: "agent" }),
        present: [],
        absent: [],
        empty: true,
      },
      {
        name: "forkable rendering",
        input: edited({
          editedHarnesses: ["claude"],
          forkableHarness: "claude",
        }),
        present: [">Keep as my own<", ">Discard edits…<"],
        absent: [],
      },
      {
        name: "several edited renderings",
        input: edited({
          editedHarnesses: ["claude", "opencode"],
          forkableHarness: null,
        }),
        present: [
          "Edited in Claude Code and OpenCode.",
          "would drop the other edits",
          ">Discard all edits…<",
          ">View changes in Claude Code<",
          ">View changes in OpenCode<",
        ],
        absent: [">Keep as my own<", ">View changes<"],
      },
      {
        name: "lone non-forkable rendering",
        input: edited({ editedHarnesses: ["opencode"], forkableHarness: null }),
        present: ["OpenCode&#x27;s copy can&#x27;t be kept as your own."],
        absent: [">Keep as my own<"],
      },
      {
        name: "owner-held derived package",
        input: edited({
          editedHarnesses: ["claude"],
          forkableHarness: null,
          derived: true,
          pinned: true,
          canDiscard: true,
          canTakeLatest: false,
        }),
        present: [">Discard edits…<"],
        absent: [">Keep as my own<"],
      },
      {
        name: "no replacement at source",
        input: edited({
          editedHarnesses: ["claude"],
          forkableHarness: "claude",
          canDiscard: false,
          canTakeLatest: false,
        }),
        present: [">View changes<"],
        absent: [">Discard edits…<"],
      },
    ];
    expect(rows).toHaveLength(6);
    for (const entry of rows) {
      const html = render([entry.input]);
      if (entry.empty) expect(html, entry.name).toBe("");
      else
        expect(
          {
            present: entry.present.filter((text) => html.includes(text)),
            forbidden: entry.absent.filter((text) => html.includes(text)),
          },
          entry.name,
        ).toEqual({ present: entry.present, forbidden: [] });
    }
  });

  it("holds Keep as my own for the work already running, and nothing else", () => {
    const rows = [
      edited({ editedHarnesses: ["claude"], forkableHarness: "claude" }),
    ];
    const forkHeld = (html: string): boolean => {
      const tag = html.match(/<button[^>]*>Keep as my own<\/button>/)?.[0];
      if (!tag) throw new Error("no Keep as my own button");
      return tag.includes('disabled=""');
    };
    const states = [
      { name: "idle", running: {}, expected: false },
      { name: "write running", running: { busy: true }, expected: true },
      { name: "check running", running: { checking: true }, expected: true },
    ];
    expect(states).toHaveLength(3);
    for (const state of states)
      expect(forkHeld(render(rows, state.running)), state.name).toBe(
        state.expected,
      );
  });

  // Discard applies the row's own latest commit where the place is held, so
  // it waits for a read that confirms the row — which the fork, copying
  // what is on disk, does not.
  it("holds Discard edits while a check is out", () => {
    const rows = [
      edited({ editedHarnesses: ["claude"], forkableHarness: "claude" }),
    ];
    const discardHeld = (html: string): boolean => {
      const tag = html.match(/<button[^>]*>Discard edits…<\/button>/)?.[0];
      if (!tag) throw new Error("no Discard edits button");
      return tag.includes('disabled=""');
    };
    const states = [
      { name: "idle", running: {}, expected: false },
      { name: "check running", running: { checking: true }, expected: true },
      { name: "write running", running: { busy: true }, expected: true },
    ];
    expect(states).toHaveLength(3);
    for (const state of states)
      expect(discardHeld(render(rows, state.running)), state.name).toBe(
        state.expected,
      );
  });
});
