import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { updateRow } from "@/components/updates-test-rows";
import { EditedNotice } from "./fork-notice";

// Static rendering reads a zustand store's initial snapshot, so the store
// hook is wrapped for the flags the buttons read. The default is a check
// that has landed, which is what every case below but the two about a
// check in flight is about.
const { standing } = vi.hoisted(() => ({
  standing: { busy: false, loaded: true, checking: false },
}));

vi.mock("@/stores/updates", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/updates")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = { ...mod.useUpdatesStore.getState(), ...standing };
    return selector ? selector(state) : state;
  };
  return { ...mod, useUpdatesStore: Object.assign(hook, mod.useUpdatesStore) };
});

// The confirmation portals itself, so what it was handed is read here
// rather than from the markup.
const { asked } = vi.hoisted(() => ({
  asked: { holdConfirm: undefined as boolean | undefined },
}));
vi.mock("@/components/confirm-dialog", () => ({
  ConfirmDialog: (props: { holdConfirm?: boolean }) => {
    asked.holdConfirm = props.holdConfirm;
    return null;
  },
}));

beforeEach(() => {
  Object.assign(standing, { busy: false, loaded: true, checking: false });
  asked.holdConfirm = undefined;
});

// The page hands the notice the one row its own place's join found, so a
// place with no hand edit hands it nothing.
const render = (row: UpdateRow | null) =>
  renderToStaticMarkup(
    <EditedNotice row={row} onViewChanges={() => {}} onResolved={() => {}} />,
  );

const edited = (extra: Partial<UpdateRow>) =>
  updateRow("rev", null, { kind: "agent", blockedByLocalEdit: true, ...extra });

/** Whether the button carrying this label is disabled. The class attribute
 *  carries the literal `disabled:pointer-events-none`, so only the rendered
 *  attribute answers this. */
const offered = (html: string, label: string) => {
  const tag = html.slice(0, html.indexOf(`>${label}<`)).lastIndexOf("<button");
  if (tag < 0) throw new Error(`no button labelled ${label}`);
  return !html.slice(tag, html.indexOf(`>${label}<`)).includes('disabled=""');
};

describe("package page edited notice", () => {
  it("shows nothing where this place holds no hand edit", () => {
    expect(render(null)).toBe("");
  });

  it("offers the fork only through the rendering the engine can take", () => {
    const html = render(
      edited({ editedHarnesses: ["claude"], forkableHarness: "claude" }),
    );
    expect(html).toContain(">Keep as my own<");
    expect(html).toContain(">Discard edits…<");
  });

  it("names the edited tools and offers only a full discard for several", () => {
    const html = render(
      edited({
        editedHarnesses: ["claude", "opencode"],
        forkableHarness: null,
      }),
    );
    expect(html).not.toContain(">Keep as my own<");
    expect(html).toContain("Edited in Claude Code and OpenCode.");
    expect(html).toContain("would drop the other edits");
    expect(html).toContain(">Discard all edits…<");
    expect(html).toContain(">View changes in Claude Code<");
    expect(html).toContain(">View changes in OpenCode<");
    expect(html).not.toContain(">View changes<");
  });

  it("says why a lone non-forkable rendering cannot become a fork", () => {
    const html = render(
      edited({ editedHarnesses: ["opencode"], forkableHarness: null }),
    );
    expect(html).not.toContain(">Keep as my own<");
    // Static markup escapes the apostrophes.
    expect(html).toContain(
      "OpenCode&#x27;s copy can&#x27;t be kept as your own.",
    );
  });

  it("keeps Discard edits for an owner-held derived package", () => {
    const html = render(
      edited({
        editedHarnesses: ["claude"],
        forkableHarness: null,
        derived: true,
        pinned: true,
        canDiscard: true,
        canTakeLatest: false,
      }),
    );
    expect(html).not.toContain(">Keep as my own<");
    expect(html).toContain(">Discard edits…<");
  });

  it("hides the discard when the source has nothing to put in its place", () => {
    const html = render(
      edited({
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
        canDiscard: false,
        canTakeLatest: false,
      }),
    );
    expect(html).not.toContain(">Discard edits…<");
    expect(html).toContain(">View changes<");
  });

  // A fork has already been kept as your own, so that half of the choice is
  // spent — but the copy you kept is still there, and a held state with no
  // way out is not a state to leave someone in.
  it("offers a fork the way back to the copy it kept, and no second fork", () => {
    const html = render(
      edited({
        forked: true,
        editedHarnesses: ["claude"],
        forkableHarness: null,
        canDiscard: true,
        canTakeLatest: false,
      }),
    );
    expect(html).not.toContain(">Keep as my own<");
    expect(html).toContain(">Discard edits…<");
    expect(html).toContain("go back to the copy you kept");
    expect(html).not.toContain("can&#x27;t be kept as your own");
  });

  // Every exit the notice advertises has to work. A fork's declaration
  // resolves to its own local source, so there is no catalog version left
  // to put beside the edit and the comparison would open nothing.
  it("offers a fork no comparison, and does not promise one", () => {
    const html = render(
      edited({
        forked: true,
        editedHarnesses: ["claude"],
        forkableHarness: null,
        canDiscard: true,
      }),
    );
    expect(html).not.toContain(">View changes<");
    expect(html).not.toContain("See what changed");
    expect(html).toContain(">Discard edits…<");
  });

  it("still offers the comparison where there is one to open", () => {
    const html = render(
      edited({ editedHarnesses: ["claude"], forkableHarness: "claude" }),
    );
    expect(html).toContain(">View changes<");
  });

  // The same button takes the newest version for a place that can move, and
  // the newest version it would take is the one the check on its way is
  // about to replace.
  it("waits for a check in flight before a place that can move may take it", () => {
    standing.checking = true;
    const html = render(
      edited({
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
        canDiscard: true,
        canTakeLatest: true,
      }),
    );
    expect(html).toContain(">Discard edits…<");
    expect(offered(html, "Discard edits…")).toBe(false);
    // And the confirmation behind it, which a reader may already have open
    // when the check goes out.
    expect(asked.holdConfirm).toBe(true);
  });

  // A place that cannot move applies no revision at all, so a check that is
  // slow — or failed outright — must not strand it with its edits held.
  it("leaves a place that can only drop its edits reachable mid-check", () => {
    standing.checking = true;
    const html = render(
      edited({
        forked: true,
        editedHarnesses: ["claude"],
        forkableHarness: null,
        canDiscard: true,
        canTakeLatest: false,
      }),
    );
    expect(offered(html, "Discard edits…")).toBe(true);
    expect(asked.holdConfirm).toBe(false);
  });

  // The copy a discard would put back cannot be read, so no button is
  // offered. A line still promising that exit would name one that refuses,
  // which is what `kendex check` already declines to do for this row.
  it("does not offer a discard whose copy can no longer be read", () => {
    const html = render(
      edited({
        forked: true,
        editedHarnesses: ["claude"],
        forkableHarness: null,
        canDiscard: false,
      }),
    );
    expect(html).not.toContain(">Discard edits…<");
    expect(html).not.toContain("Discard them to go back");
    expect(html).toContain("can no longer be read");
  });
});
