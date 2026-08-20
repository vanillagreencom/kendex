import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { UpdatesTable } from "./updates-table";
import { updateRow as row } from "./updates-test-rows";

// Static rendering reads a zustand store's initial snapshot, never one set
// later, so the store hook is wrapped to let a test flip `busy`.
const stub = vi.hoisted(() => ({ busy: false }));
vi.mock("@/stores/updates", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/updates")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = { ...mod.useUpdatesStore.getState(), busy: stub.busy };
    return selector ? selector(state) : state;
  };
  return { ...mod, useUpdatesStore: Object.assign(hook, mod.useUpdatesStore) };
});

const render = (rows: UpdateRow[]) =>
  renderToStaticMarkup(<UpdatesTable rows={rows} onIgnore={() => {}} />);

describe("customized places", () => {
  it("offers the fork decision instead of Update where files were edited", () => {
    const html = render([
      row("one", null, {
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
      }),
    ]);
    expect(html).toContain(">Customized here<");
    expect(html).toContain(">Keep as my own<");
    expect(html).toContain(">Use new version…<");
    expect(html).not.toContain(">Update<");
  });

  it("offers no fork for an edit only a non-forkable tool holds", () => {
    const html = render([
      row("rev", null, {
        kind: "agent",
        blockedByLocalEdit: true,
        editedHarnesses: ["opencode"],
        forkableHarness: null,
        canDiscard: true,
      }),
    ]);
    expect(html).not.toContain(">Keep as my own<");
    expect(html).toContain("Edited in a tool whose copy can");
    expect(html).toContain(">Use new version…<");
    expect(html).toContain(">Preview changes<");
  });

  it("points an edited bundle member at the package page", () => {
    const html = render([
      row("gh", null, {
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: null,
        derived: true,
      }),
    ]);
    expect(html).not.toContain(">Keep as my own<");
    expect(html).toContain("Comes with a bundle or another package");
    expect(html).toContain(">Use new version…<");
  });

  it("withholds the new version from a bundle member its bundle holds back", () => {
    const html = render([
      row("gh", null, {
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: null,
        derived: true,
        pinned: true,
        canDiscard: false,
      }),
    ]);
    expect(html).not.toContain(">Keep as my own<");
    expect(html).not.toContain(">Use new version…<");
    expect(html).toContain("Comes with a bundle or another package");
  });

  it("points edits in several tools at the package page", () => {
    const html = render([
      row("rev", null, {
        kind: "agent",
        blockedByLocalEdit: true,
        editedHarnesses: ["claude", "opencode"],
        forkableHarness: null,
      }),
    ]);
    expect(html).not.toContain(">Keep as my own<");
    expect(html).toContain("Edited in several tools");
    expect(html).toContain(">Use new version…<");
  });

  it("offers no new version when the source no longer carries the package", () => {
    const html = render([
      row("gh", null, {
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
        updateAvailable: false,
        removedUpstream: true,
        latest: null,
        canDiscard: false,
      }),
    ]);
    expect(html).toContain(">Keep as my own<");
    expect(html).not.toContain(">Use new version…<");
    expect(html).toContain(">No longer in its source<");
  });

  it("holds the fork decision while another update is running", () => {
    stub.busy = true;
    try {
      const html = render([
        row("one", null, {
          blockedByLocalEdit: true,
          editedHarnesses: ["claude"],
          forkableHarness: "claude",
        }),
      ]);
      expect(html).toMatch(/<button[^>]*disabled=""[^>]*>Keep as my own</);
      expect(html).toMatch(/<span[^>]*data-disabled=""[^>]*role="switch"/);
      expect(html).toMatch(/<button[^>]*disabled=""[^>]*>Use new version…</);
    } finally {
      stub.busy = false;
    }
  });
});
