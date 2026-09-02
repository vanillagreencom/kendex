import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { DirectoryRow } from "@/bindings";
import { FEATURED_MARKER, SUBSCRIBED_MARKER } from "@/lib/copy-marketplaces";
import { DirectoryCard } from "./directory-card";

const listed = (over: Partial<DirectoryRow> = {}): DirectoryRow => ({
  repo: "Acme/Kit",
  repoKey: "acme/kit",
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
  // The two states a card can be in are told apart by colour as well as by
  // words: the marker a person already has is the green one, and featured
  // is the warm accent rather than the grey every other badge wears.
  it("marks a subscription in green instead of offering Subscribe again", () => {
    const html = render(listed(), true);
    expect(html).toContain(SUBSCRIBED_MARKER);
    expect(html).toContain("text-good");
    expect(html).not.toContain(">Subscribe<");
  });

  it("offers Subscribe when the live list does not hold it", () => {
    const html = render(listed(), false);
    expect(html).toContain(">Subscribe<");
    expect(html).not.toContain(SUBSCRIBED_MARKER);
  });

  it("draws featured in the warm accent", () => {
    const html = render(listed({ featured: true }));
    expect(html).toContain(FEATURED_MARKER);
    expect(html).toContain('data-variant="warning"');
  });

  it("carries no featured badge for a row that is not featured", () => {
    expect(render(listed())).not.toContain(FEATURED_MARKER);
  });

  // The counts were a bare "42 pkgs · 4 bundles" dropped mid-row. They are
  // still there, spelled out, and set as metadata.
  it("says its counts in words, as metadata", () => {
    const html = render(listed());
    expect(html).toContain("42 packages · 4 bundles");
    expect(html).toContain("text-muted-foreground");
  });

  it("leaves bundles out of the counts when it declares none", () => {
    const html = render(listed({ bundleCount: 0 }));
    expect(html).toContain("42 packages");
    expect(html).not.toContain("bundle");
  });
});
