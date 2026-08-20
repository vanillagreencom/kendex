import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { Table, TableBody } from "@/components/ui/table";
import { groupUpdates } from "@/lib/update-groups";
import { PackageRows, UpdatesTable } from "./updates-table";

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

const row = (
  name: string,
  root: string | null,
  extra: Partial<UpdateRow> = {},
): UpdateRow => ({
  scope: root ? { scope: "project", root } : { scope: "global" },
  kind: "skill",
  name,
  source: "kendex",
  repo: "vanillagreencom/kendex",
  repoIdentity: "vanillagreencom/kendex",
  current: { commit: "1111111111", label: null, date: null },
  latest: { commit: "2222222222", label: "v2", date: null },
  updateAvailable: true,
  pinned: false,
  blockedByLocalEdit: false,
  editedHarnesses: [],
  forkableHarness: null,
  removedUpstream: false,
  mixed: false,
  forked: false,
  ignored: false,
  ...extra,
});

const render = (rows: UpdateRow[]) =>
  renderToStaticMarkup(<UpdatesTable rows={rows} onIgnore={() => {}} />);

describe("UpdatesTable", () => {
  it("names the follow-source column once in the header, not per row", () => {
    const html = render([row("one", null), row("two", null)]);
    expect(html.match(/<th[^>]*>Follow source<\/th>/g)).toHaveLength(1);
    expect(html).not.toContain("automatically");
    expect(html.match(/role="switch"/g)).toHaveLength(2);
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

  it("disables a package's Update all when every place needs a decision", () => {
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
      }),
    ]);
    expect(html).not.toContain(">Keep as my own<");
    expect(html).toContain("Edited in a tool whose copy can");
    expect(html).toContain(">Use new version…<");
    expect(html).toContain(">Preview changes<");
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
      expect(html).toMatch(/<button[^>]*disabled=""[^>]*>Use new version…</);
    } finally {
      stub.busy = false;
    }
  });

  it("swaps the toggle and actions for a muted row", () => {
    const html = render([row("one", null, { ignored: true })]);
    expect(html).not.toContain('role="switch"');
    expect(html).toContain(">Notify again<");
  });
});
