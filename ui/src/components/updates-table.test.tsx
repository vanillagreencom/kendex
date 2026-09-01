import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { Table, TableBody } from "@/components/ui/table";
import {
  EDITED_CANT_UPDATE_NOTE,
  EDITED_TAG_HELP,
  FOLLOW_SOURCE_HELP,
  INSTALL_AS_NEW_LABEL,
  OPEN_PACKAGE_LABEL,
  UPDATE_NEEDS_CHECK_NOTE,
} from "@/lib/copy-updates";
import { groupUpdates } from "@/lib/update-groups";
import { PackageRows, UpdatesTable } from "./updates-table";
import { updateRow as row } from "./updates-test-rows";

const render = (rows: UpdateRow[]) =>
  renderToStaticMarkup(<UpdatesTable rows={rows} onIgnore={() => {}} />);

// Static markup escapes apostrophes, so copy with one is looked for the
// same way.
const esc = (copy: string) => copy.replace(/'/g, "&#x27;");

// A tooltip popup is portalled and only mounts once open, so the trigger's
// own contents are the whole of what a reader gets without a pointer.
const triggers = (html: string): string[] =>
  [
    ...html.matchAll(
      /data-slot="tooltip-trigger"[^>]*>(.*?)<\/(button|span)>/g,
    ),
  ].map((m) => m[1]);

// Static rendering reads a zustand store's initial snapshot, never one set
// later, so the store is wrapped to let a test stage what the last read
// left behind. Rows on the table imply a read that answered, so that is
// the default.
const stub = vi.hoisted(() => ({
  loaded: true,
  busy: false,
  checking: false,
  showVersion: false,
}));

vi.mock("@/stores/updates", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/updates")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useUpdatesStore.getState(),
      loaded: stub.loaded,
      busy: stub.busy,
      checking: stub.checking,
    };
    return selector ? selector(state) : state;
  };
  return { ...mod, useUpdatesStore: Object.assign(hook, mod.useUpdatesStore) };
});

// The Version column follows the page-wide choice; the same wrapping lets
// a static render see it switched on.
vi.mock("@/stores/updates-view", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/updates-view")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useUpdatesView.getState(),
      showVersion: stub.showVersion,
    };
    return selector ? selector(state) : state;
  };
  return { ...mod, useUpdatesView: Object.assign(hook, mod.useUpdatesView) };
});

beforeEach(() => {
  stub.loaded = true;
  stub.busy = false;
  stub.showVersion = false;
});

describe("UpdatesTable", () => {
  it("names the follow-source column once in the header, and explains it there", () => {
    const html = render([row("one", null), row("two", null)]);
    expect(html.match(/Follow source/g)).toHaveLength(1);
    expect(html).not.toContain("automatically");
    expect(html.match(/role="switch"/g)).toHaveLength(2);
    // One sentence, on the header, reachable without a pointer.
    expect(triggers(html).some((t) => t.includes(FOLLOW_SOURCE_HELP))).toBe(
      true,
    );
    expect(html.match(new RegExp(FOLLOW_SOURCE_HELP, "g"))).toHaveLength(1);
  });

  // Commit ids mean little to most people: the column is off until asked
  // for from the table's own menu, and the row's cells go with it.
  it("keeps the Version column off until asked, in the header and the rows", () => {
    const html = render([row("one", null)]);
    expect(html).not.toContain(">Version<");
    expect(html).not.toContain("→");
    expect(html.match(/<th\b/g)).toHaveLength(5);
    expect(html).not.toContain('aria-label="Table options"');

    stub.showVersion = true;
    const shown = render([row("one", null)]);
    expect(shown).toContain(">Version<");
    expect(shown).toContain("1111111 → v2");
    expect(shown.match(/<th\b/g)).toHaveLength(6);
  });

  it("offers the table options only where the page puts them", () => {
    const html = renderToStaticMarkup(
      <UpdatesTable
        rows={[row("one", null)]}
        onIgnore={() => {}}
        onShowVersion={() => {}}
      />,
    );
    expect(html).toContain('aria-label="Table options"');
  });

  // An edited copy is the user's work: the row says it cannot be updated
  // and offers the one way to a newer version — beside it, never over it.
  it("says an edited place can't be updated and offers Install as new package", () => {
    const html = render([
      row("gh", null, {
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
      }),
    ]);
    expect(html).toContain(esc(EDITED_CANT_UPDATE_NOTE));
    expect(html).toContain(`>${INSTALL_AS_NEW_LABEL}<`);
    expect(html).toContain(">Preview changes<");
    expect(html).not.toContain(">Update<");
    expect(html).not.toContain("Customized here");
    expect(html).not.toContain("Use new version");
    expect(html).not.toContain("Keep as my own");
  });

  // With nothing newer the source still carries, there is nothing to put
  // beside the edits: the fork-or-discard choice on the package page is
  // what is left, and the row says where.
  it("offers no install beside where there is nothing to install", () => {
    const edited = {
      blockedByLocalEdit: true,
      editedHarnesses: ["claude" as const],
      forkableHarness: "claude" as const,
    };
    const gone = render([
      row("gh", null, {
        ...edited,
        latest: null,
        updateAvailable: false,
        canDiscard: false,
        removedUpstream: true,
      }),
    ]);
    expect(gone).toContain(esc(EDITED_CANT_UPDATE_NOTE));
    expect(gone).not.toContain(`>${INSTALL_AS_NEW_LABEL}<`);
    expect(gone).not.toContain(">Update<");
    // Nothing to compare either: the package page is the route.
    expect(gone).not.toContain(">Preview changes<");
    expect(gone).toContain(`>${OPEN_PACKAGE_LABEL}<`);

    const current = render([
      row("gh", null, { ...edited, updateAvailable: false }),
    ]);
    expect(current).toContain(esc(EDITED_CANT_UPDATE_NOTE));
    expect(current).not.toContain(`>${INSTALL_AS_NEW_LABEL}<`);
    expect(current).not.toContain(">Update<");
    expect(current).toContain(">Preview changes<");
  });

  it("holds Install as new package while the store is busy", () => {
    stub.busy = true;
    const html = render([
      row("gh", null, {
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
      }),
    ]);
    expect(html).toMatch(
      new RegExp(`<button[^>]*disabled=""[^>]*>${INSTALL_AS_NEW_LABEL}<`),
    );
  });

  it("offers no install beside where the edited rendering can't be kept", () => {
    for (const extra of [
      { kind: "agent" as const, editedHarnesses: ["opencode" as const] },
      { editedHarnesses: ["claude" as const, "codex" as const] },
      { editedHarnesses: ["claude" as const], derived: true },
    ]) {
      const html = render([
        row("gh", null, {
          blockedByLocalEdit: true,
          forkableHarness: null,
          ...extra,
        }),
      ]);
      expect(html).toContain(esc(EDITED_CANT_UPDATE_NOTE));
      expect(html).not.toContain(`>${INSTALL_AS_NEW_LABEL}<`);
      expect(html).not.toContain(">Update<");
      expect(html).toContain(">Preview changes<");
    }
  });

  it("explains the Edited by you tag where a keyboard reaches it", () => {
    const html = render([
      row("gh", null, {
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
      }),
    ]);
    const tag = triggers(html).find((t) => t.includes("Edited by you"));
    expect(tag).toContain(`<span class="sr-only">${esc(EDITED_TAG_HELP)}`);
    expect(html).toMatch(/data-slot="tooltip-trigger"[^>]*tabindex="0"/);
  });

  // The install may move a hold to the row's `latest`, which stale rows
  // name without anyone confirming — it waits for a check like Update.
  it("holds Install as new package on rows a failed check left behind", () => {
    stub.loaded = false;
    const html = render([
      row("gh", null, {
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
      }),
    ]);
    expect(html).toMatch(
      new RegExp(
        `<button[^>]*disabled=""[^>]*title="${UPDATE_NEEDS_CHECK_NOTE}"[^>]*>${INSTALL_AS_NEW_LABEL}<`,
      ),
    );
  });

  it("names the place on a single-place row and labels its switch", () => {
    const html = render([
      row("one", null, { pinned: true }),
      row("two", "/home/x/acme"),
    ]);
    expect(html).toContain(">User level<");
    expect(html).toContain('title="/home/x/acme"');
    expect(html).toMatch(
      /aria-checked="false"[^>]*aria-label="Follow the source for one in User level"/,
    );
    expect(html).toMatch(
      /aria-checked="true"[^>]*aria-label="Follow the source for two in acme"/,
    );
  });

  it("folds a package's places into one collapsed row with Update all", () => {
    const html = render([
      row("gh", null),
      row("gh", "/home/x/acme"),
      row("gh", "/home/x/shop"),
    ]);
    expect(html.match(/<tr/g)).toHaveLength(2);
    expect(html).toContain(">3 places<");
    expect(html).toContain('aria-expanded="false"');
    expect(html).toContain(">Update all<");
    expect(html).not.toContain('role="switch"');
    expect(html).not.toContain(">Preview changes<");
    // The collapsed row's cells line up under the header's columns, the
    // Version spacer included only when the column is drawn.
    expect(html.match(/<td\b/g)).toHaveLength(5);
    stub.showVersion = true;
    const shown = render([
      row("gh", null),
      row("gh", "/home/x/acme"),
      row("gh", "/home/x/shop"),
    ]);
    expect(shown.match(/<td\b/g)).toHaveLength(6);
    expect(shown.match(/<th\b/g)).toHaveLength(6);
  });

  it("expands a package into one row per place, each with its own controls", () => {
    const rows = [
      row("gh", null, { pinned: true }),
      row("gh", "/home/x/acme"),
      row("gh", "/home/x/shop"),
    ];
    const html = renderToStaticMarkup(
      <Table>
        <TableBody>
          <PackageRows
            group={groupUpdates(rows)[0]}
            onIgnore={() => {}}
            defaultOpen
          />
        </TableBody>
      </Table>,
    );
    expect(html.match(/<tr/g)).toHaveLength(4);
    expect(html).toContain('aria-expanded="true"');
    expect(html).toMatch(/aria-controls="([^"]+)"[\s\S]*<tr[^>]*id="\1"/);
    expect(html).toContain(">Update all<");
    expect(html).toContain(">Held in 1 of 3<");
    for (const place of ["User level", "acme", "shop"]) {
      expect(html).toContain(`>${place}<`);
      expect(html).toContain(
        `aria-label="Follow the source for gh in ${place}"`,
      );
    }
    expect(html.match(/role="switch"/g)).toHaveLength(3);
    expect(html.match(/>Preview changes</g)).toHaveLength(3);
    expect(html.match(/>Update</g)).toHaveLength(3);
  });

  it("tells same-named project folders apart by their parent", () => {
    const html = renderToStaticMarkup(
      <Table>
        <TableBody>
          <PackageRows
            group={
              groupUpdates([
                row("gh", "/home/x/work/app"),
                row("gh", "/home/x/clients/app/"),
              ])[0]
            }
            defaultOpen
          />
        </TableBody>
      </Table>,
    );
    expect(html).toContain(">work/app<");
    expect(html).toContain(">clients/app<");
  });

  it("disables a package's Update all when every place is edited", () => {
    const html = render([
      row("gh", null, {
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
      }),
      row("gh", "/home/x/acme", {
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
      }),
    ]);
    expect(html).toMatch(/<button[^>]*disabled=""[^>]*>Update all</);
  });

  it("disables Update and the switch on a place its owner holds", () => {
    const html = render([row("gh", null, { derived: true, pinned: true })]);
    expect(html).toMatch(
      /<button[^>]*disabled=""[^>]*title="Held by the bundle or package it came with[^"]*"[^>]*>Update</,
    );
    expect(html).toMatch(/<span[^>]*data-disabled=""[^>]*role="switch"/);
  });

  it("locks the switch on a place its source holds, and says where to release it", () => {
    const html = render([
      row("gh", null, {
        pinned: true,
        holdOwner: { kind: "source", name: "cat" },
      }),
    ]);
    expect(html).toMatch(/<span[^>]*data-disabled=""[^>]*role="switch"/);
    expect(html).toContain(
      "Held by the source &quot;cat&quot; as a whole — release it where that source is declared",
    );
    expect(html).toMatch(/<button[^>]*>Update</);
  });

  // Rows kept from before a failed check name a `latest` nobody confirmed
  // — updating from them would move a hold to a stale commit, so every
  // Update action waits for a check that succeeds.
  it("holds every Update action on rows a failed check left behind", () => {
    stub.loaded = false;
    const html = renderToStaticMarkup(
      <Table>
        <TableBody>
          <PackageRows
            group={
              groupUpdates([row("gh", null), row("gh", "/home/x/acme")])[0]
            }
            onIgnore={() => {}}
            defaultOpen
          />
        </TableBody>
      </Table>,
    );
    expect(html).toMatch(/<button[^>]*disabled=""[^>]*>Update all</);
    expect(html.match(/<button[^>]*disabled=""[^>]*>Update</g)).toHaveLength(2);
    // The Follow switch holds at row.current's commit when switched off —
    // a stale row would pin an old version — so it waits too.
    expect(
      html.match(/<span[^>]*data-disabled=""[^>]*role="switch"/g),
    ).toHaveLength(2);
    expect(
      html.match(new RegExp(`title="${UPDATE_NEEDS_CHECK_NOTE}"`, "g")),
    ).toHaveLength(5);
  });

  it("offers no package-wide Update all in the muted table", () => {
    const html = renderToStaticMarkup(
      <UpdatesTable
        rows={[
          row("gh", null, { ignored: true }),
          row("gh", "/home/x/acme", { ignored: true }),
        ]}
      />,
    );
    expect(html).toContain(">2 places<");
    expect(html).not.toContain(">Update all<");
  });

  it("shows the kind as a column and the actions in every row", () => {
    const html = render([row("one", null, { kind: "agent" })]);
    expect(html).toContain(">Agent<");
    expect(html).toContain(">Preview changes<");
    expect(html).toContain(">Update<");
    expect(html).toContain('aria-label="More actions"');
  });

  it("swaps the toggle and actions for a muted row", () => {
    const html = render([row("one", null, { ignored: true })]);
    expect(html).not.toContain('role="switch"');
    expect(html).toContain(">Notify again<");
  });

  // The mute is the one action `rowUnsettled` does not bar, so its
  // surfaces carry the pair the store refuses on instead. Without them the
  // button invites a click the store answers with an error. The `…` menu's
  // Ignore item takes the same pair; it renders only once opened, so it is
  // held in `updates-table.dom.test.tsx`.
  it("holds Notify again while a check or a write is out", () => {
    for (const flag of ["busy", "checking"] as const) {
      stub.busy = false;
      stub.checking = false;
      stub[flag] = true;
      const muted = render([row("one", null, { ignored: true })]);
      expect(muted).toMatch(
        /<button[^>]*disabled=""[^>]*>(?:(?!<button)[\s\S])*?Notify again</,
      );
    }
    stub.busy = false;
    stub.checking = false;
  });
});
