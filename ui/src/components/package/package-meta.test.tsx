import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ProvenanceRow } from "@/bindings";
import { groupItems } from "@/lib/derive";
import { observedItem } from "@/lib/observed-test-item";
import { VG } from "@/lib/places-test-source";
import { PackageMetaBlock } from "./package-meta";

const state = vi.hoisted(() => ({
  rows: [] as ProvenanceRow[],
  loaded: true,
  error: null as string | null,
  load: vi.fn(),
}));
vi.mock("@/stores/provenance", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/provenance")>();
  const hook = (selector?: (s: unknown) => unknown) =>
    selector ? selector(state) : state;
  return {
    ...mod,
    useProvenanceStore: Object.assign(hook, { getState: () => state }),
  };
});

const item = observedItem({ name: "gh", scope: VG });

const render = () => {
  const group = groupItems([item])[0];
  return renderToStaticMarkup(
    <PackageMetaBlock group={group} primary={item} meta={null} />,
  );
};

beforeEach(() => {
  state.rows = [
    {
      kind: "skill",
      name: "gh",
      scope: VG,
      origin: { origin: "marketplace", source: "kendex", repo: "vg/kendex" },
    } as unknown as ProvenanceRow,
  ];
  state.error = null;
});

// A refresh that fails keeps the rows already on screen, so the From row
// still has something to draw. What it must not do is draw it as current.
describe("the From row when the join could not be re-read", () => {
  it("shows where the package came from when the read succeeded", () => {
    const html = render();
    expect(html).toContain("kendex");
    expect(html).not.toContain("last known");
  });

  it("keeps the last origin but says it is not confirmed", () => {
    state.error = "provenance read failed";
    const html = render();
    expect(html).toContain("kendex");
    expect(html).toContain("last known");
  });

  it("says the read failed when there is no origin to keep", () => {
    state.rows = [];
    state.error = "provenance read failed";
    const html = render();
    // The apostrophe arrives HTML-escaped from static markup.
    expect(html).toContain("be read");
    expect(html).not.toContain("kendex");
  });
});
