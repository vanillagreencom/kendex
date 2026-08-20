import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { updateRow } from "@/components/updates-test-rows";
import { EditedNotice } from "./fork-notice";

// Static rendering reads a zustand store's initial snapshot, so the store
// hook is wrapped to let each test seed the rows it needs.
const stub = vi.hoisted(() => ({ rows: [] as unknown[] }));
vi.mock("@/stores/updates", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/updates")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = { ...mod.useUpdatesStore.getState(), rows: stub.rows };
    return selector ? selector(state) : state;
  };
  return { ...mod, useUpdatesStore: Object.assign(hook, mod.useUpdatesStore) };
});

const render = (rows: UpdateRow[]) => {
  stub.rows = rows;
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

  it("hides the discard when the source has nothing to put in its place", () => {
    const html = render([
      edited({
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
        canDiscard: false,
      }),
    ]);
    expect(html).not.toContain(">Discard edits…<");
    expect(html).toContain(">View changes<");
  });
});
