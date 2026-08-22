import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { UpdatesTable } from "./updates-table";
import { updateRow as row } from "./updates-test-rows";

// Static rendering reads a zustand store's initial snapshot, never one set
// later, so the store hook is wrapped to let a test flip what it says. The
// default is a check that has landed, which every case but the last is
// about.
const stub = vi.hoisted(() => ({
  busy: false,
  loaded: true,
  checking: false,
}));
vi.mock("@/stores/updates", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/updates")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = { ...mod.useUpdatesStore.getState(), ...stub };
    return selector ? selector(state) : state;
  };
  return { ...mod, useUpdatesStore: Object.assign(hook, mod.useUpdatesStore) };
});

// The confirmation portals itself, so what it was handed is read here
// rather than from the markup.
const asked = vi.hoisted(() => ({
  holdConfirm: undefined as boolean | undefined,
}));
vi.mock("@/components/confirm-dialog", () => ({
  ConfirmDialog: (props: { holdConfirm?: boolean }) => {
    asked.holdConfirm = props.holdConfirm;
    return null;
  },
}));

beforeEach(() => {
  Object.assign(stub, { busy: false, loaded: true, checking: false });
  asked.holdConfirm = undefined;
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

  it("offers a bundle member its bundle holds back a discard, not a new version", () => {
    const html = render([
      row("gh", null, {
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: null,
        derived: true,
        pinned: true,
        canDiscard: true,
        canTakeLatest: false,
      }),
    ]);
    expect(html).not.toContain(">Keep as my own<");
    expect(html).not.toContain(">Use new version…<");
    expect(html).toContain(">Discard edits…<");
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
        canTakeLatest: false,
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

// The gate reached the button that opens the confirmation but not the
// confirmation itself, so a check that failed while it stood open still
// applied the version it was about to replace.
describe("a confirmation left open across a check", () => {
  it("holds the answer for a place that would take the newest", () => {
    render([
      row("one", null, {
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
        canDiscard: true,
        canTakeLatest: true,
      }),
    ]);
    expect(asked.holdConfirm).toBe(false);

    stub.checking = true;
    render([
      row("one", null, {
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
        canDiscard: true,
        canTakeLatest: true,
      }),
    ]);
    expect(asked.holdConfirm).toBe(true);
  });

  it("leaves a place that can only drop its edits answerable", () => {
    stub.checking = true;
    render([
      row("one", null, {
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
        canDiscard: true,
        canTakeLatest: false,
      }),
    ]);
    expect(asked.holdConfirm).toBe(false);
  });
});
