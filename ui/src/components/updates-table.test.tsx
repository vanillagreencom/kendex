import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { UpdateRow } from "@/bindings";
import { UpdatesTable } from "./updates-table";

const row = (name: string, extra: Partial<UpdateRow> = {}): UpdateRow => ({
  scope: { scope: "global" },
  kind: "skill",
  name,
  source: "kendex",
  repo: "vanillagreencom/kendex",
  current: { commit: "1111111111", label: null, date: null },
  latest: { commit: "2222222222", label: "v2", date: null },
  updateAvailable: true,
  pinned: false,
  blockedByLocalEdit: false,
  removedUpstream: false,
  mixed: false,
  forked: false,
  ignored: false,
  ...extra,
});

const render = (rows: UpdateRow[]) =>
  renderToStaticMarkup(<UpdatesTable rows={rows} onIgnore={() => {}} />);

describe("UpdatesTable", () => {
  it("names the auto-update column once in the header, not per row", () => {
    const html = render([row("one"), row("two"), row("three")]);
    expect(html.match(/<th[^>]*>Auto-update<\/th>/g)).toHaveLength(1);
    expect(html).not.toContain(">Update automatically<");
    expect(html.match(/role="switch"/g)).toHaveLength(3);
  });

  it("labels each row's switch by its package", () => {
    const html = render([row("one", { pinned: true }), row("two")]);
    expect(html).toContain('aria-label="Update one automatically"');
    expect(html).toMatch(
      /aria-checked="false"[^>]*aria-label="Update one automatically"/,
    );
    expect(html).toMatch(
      /aria-checked="true"[^>]*aria-label="Update two automatically"/,
    );
  });

  it("shows the kind as a column and the actions in every row", () => {
    const html = render([row("one", { kind: "agent" })]);
    expect(html).toContain(">Agent<");
    expect(html).toContain(">Preview changes<");
    expect(html).toContain(">Update<");
    expect(html).toContain('aria-label="More actions"');
  });

  it("swaps the toggle and actions for a muted row", () => {
    const html = render([row("one", { ignored: true })]);
    expect(html).not.toContain('role="switch"');
    expect(html).toContain(">Notify again<");
  });
});
