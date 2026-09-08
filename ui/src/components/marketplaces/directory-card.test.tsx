import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { DirectoryRow } from "@/bindings";
import { FEATURED_MARKER, SUBSCRIBED_MARKER } from "@/lib/copy-marketplaces";
import { DirectoryCard } from "./directory-card";

const listed = (over: Partial<DirectoryRow> = {}): DirectoryRow => ({
  repo: "Acme/Kit",
  repoKey: "acme/kit",
  repoIdentity: "github.com/acme/kit",
  name: "kit",
  description: "Skills for the Acme stack.",
  tags: [],
  featured: false,
  packageCount: 42,
  bundleCount: 4,
  subscribed: false,
  packages: [],
  bundles: [],
  ...over,
});

const render = (row: DirectoryRow, subscribed = false) =>
  renderToStaticMarkup(
    <DirectoryCard
      row={row}
      subscribed={subscribed}
      onOpen={() => {}}
      onSubscribe={() => {}}
    />,
  );

describe("a listed marketplace's card", () => {
  it("offers Subscribe only for a marketplace absent from the live list", () => {
    const rows = [
      { name: "subscribed", subscribed: true },
      { name: "not subscribed", subscribed: false },
    ];
    expect(rows).toHaveLength(2);
    for (const row of rows) {
      const html = render(listed(), row.subscribed);
      if (row.subscribed) {
        expect(html, row.name).toContain(SUBSCRIBED_MARKER);
        expect(html, row.name).toContain("text-good");
        expect(html, row.name).not.toContain(">Subscribe<");
      } else {
        expect(html, row.name).toContain(">Subscribe<");
        expect(html, row.name).not.toContain(SUBSCRIBED_MARKER);
      }
    }
  });

  it("marks featured marketplaces with the warm accent", () => {
    const rows = [{ featured: true }, { featured: false }];
    expect(rows).toHaveLength(2);
    for (const row of rows) {
      const html = render(listed(row));
      if (row.featured) {
        expect(html).toContain(FEATURED_MARKER);
        expect(html).toContain('data-variant="warning"');
      } else expect(html).not.toContain(FEATURED_MARKER);
    }
  });

  it("names declared counts and omits an empty bundle count", () => {
    const rows = [
      { bundleCount: 4, shown: "42 packages · 4 bundles" },
      { bundleCount: 0, shown: "42 packages" },
    ];
    expect(rows).toHaveLength(2);
    for (const row of rows) {
      const html = render(listed({ bundleCount: row.bundleCount }));
      expect(html).toContain(row.shown);
      if (row.bundleCount === 0) expect(html).not.toContain("bundle");
      else expect(html).toContain("text-muted-foreground");
    }
  });
});
