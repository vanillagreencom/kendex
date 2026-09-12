import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { updateRow } from "@/components/updates-test-rows";
import { MISSING_FILES_NOTICE_TITLE } from "@/lib/copy";
import { REPAIR_LABEL } from "@/lib/copy-setup";
import { READ_LANDED, type ReadState, readFailed } from "@/lib/read-state";
import { MissingFilesNotice } from "./missing-files-notice";

// Static rendering reads a zustand store's initial snapshot, so the store
// hook is wrapped to let each test seed the rows it needs.
const stub = vi.hoisted(() => ({
  rows: [] as unknown[],
  busy: false,
  landed: true,
}));
vi.mock("@/stores/updates", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/updates")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    // Typed as the store's own read state, so a case cannot name a
    // status the production code never produces.
    const read: ReadState = stub.landed ? READ_LANDED : readFailed("no");
    const state = {
      ...mod.useUpdatesStore.getState(),
      rows: stub.rows,
      read,
      busy: stub.busy,
      checking: false,
    };
    return selector ? selector(state) : state;
  };
  return { ...mod, useUpdatesStore: Object.assign(hook, mod.useUpdatesStore) };
});

const render = (
  rows: UpdateRow[],
  state: { busy?: boolean; landed?: boolean } = {},
) => {
  stub.rows = rows;
  stub.busy = state.busy ?? false;
  stub.landed = state.landed ?? true;
  return renderToStaticMarkup(
    <MissingFilesNotice
      scope={{ scope: "global" }}
      kind="hook"
      name="guard"
      onResolved={() => {}}
    />,
  );
};

const repairHeld = (html: string): boolean => {
  const tag = html.match(/<button[^>]*>Repair<\/button>/)?.[0];
  if (!tag) throw new Error("no Repair button");
  return tag.includes('disabled=""');
};

describe("package page missing files notice", () => {
  // The notice is this place's row and nothing wider: the same package
  // missing a file in another project says nothing here, and a row with
  // every file in place says nothing at all.
  it("shows the repair exactly where this place's row says a file is gone", () => {
    const rows = [
      {
        name: "file gone here",
        input: updateRow("guard", null, { kind: "hook", filesMissing: true }),
        shown: true,
      },
      {
        name: "every file in place",
        input: updateRow("guard", null, { kind: "hook" }),
        shown: false,
      },
      {
        name: "file gone in another place",
        input: updateRow("guard", "/work/vg", {
          kind: "hook",
          filesMissing: true,
        }),
        shown: false,
      },
    ];
    expect(rows).toHaveLength(3);
    for (const entry of rows) {
      const html = render([entry.input]);
      expect(html.includes(MISSING_FILES_NOTICE_TITLE), entry.name).toBe(
        entry.shown,
      );
      expect(html.includes(`>${REPAIR_LABEL}<`), entry.name).toBe(entry.shown);
    }
  });

  // The repair applies the row it is handed, so it waits on the same two
  // holds an update does: a write already running, and a read that has
  // not confirmed the row.
  it("holds Repair for a running write and an unsettled read", () => {
    const rows = [
      updateRow("guard", null, { kind: "hook", filesMissing: true }),
    ];
    const states = [
      { name: "idle", state: {}, expected: false },
      { name: "write running", state: { busy: true }, expected: true },
      { name: "read failed", state: { landed: false }, expected: true },
    ];
    expect(states).toHaveLength(3);
    for (const one of states)
      expect(repairHeld(render(rows, one.state)), one.name).toBe(one.expected);
  });
});
