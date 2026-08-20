import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { UpdateRow } from "@/bindings";
import { UpdatesTable } from "./updates-table";

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

  it("shows the kind as a column and the actions in every row", () => {
    const html = render([row("one", null, { kind: "agent" })]);
    expect(html).toContain(">Agent<");
    expect(html).toContain(">Preview changes<");
    expect(html).toContain(">Update<");
    expect(html).toContain('aria-label="More actions"');
  });

  it("offers the fork decision instead of Update where files were edited", () => {
    const html = render([row("one", null, { blockedByLocalEdit: true })]);
    expect(html).toContain(">Customized here<");
    expect(html).toContain(">Keep as my own<");
    expect(html).toContain(">Use new version…<");
    expect(html).not.toContain(">Update<");
  });

  it("swaps the toggle and actions for a muted row", () => {
    const html = render([row("one", null, { ignored: true })]);
    expect(html).not.toContain('role="switch"');
    expect(html).toContain(">Notify again<");
  });
});
