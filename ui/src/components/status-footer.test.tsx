import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { scanFailedStatusLabel, scanStatusLabel } from "@/lib/copy-footer";
import { StatusFooter } from "./status-footer";

// Static markup escapes apostrophes, so a pinned copy token must be
// escaped the same way before it can be looked for.
const esc = (copy: string) => copy.replace(/'/g, "&#x27;");

// Static rendering reads a zustand store's initial snapshot, never one set
// later, so the store is wrapped to let a test stage how the last scan
// went.
const stub = vi.hoisted(() => ({
  scanning: false,
  lastScanAt: null as number | null,
  error: null as string | null,
}));

vi.mock("@/stores/scan", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/scan")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = { ...mod.useScanStore.getState(), ...stub };
    return selector ? selector(state) : state;
  };
  return { ...mod, useScanStore: Object.assign(hook, mod.useScanStore) };
});

beforeEach(() => {
  stub.scanning = false;
  stub.lastScanAt = null;
  stub.error = null;
});

// The footer is mounted on every page: "Up to date" beside a failed scan
// would have it and Home answering the same question oppositely.
describe("the status footer across scan states", () => {
  it("calls a failed first scan failed, not up to date", () => {
    stub.error = "config unreadable";
    const html = renderToStaticMarkup(<StatusFooter />);
    expect(html).toContain(esc(scanFailedStatusLabel(null)));
    expect(html).not.toContain(scanStatusLabel(null));
  });

  it("labels a kept result last-known when a later scan fails", () => {
    stub.error = "no disk";
    stub.lastScanAt = Date.now() - 60_000;
    const html = renderToStaticMarkup(<StatusFooter />);
    // The age suffix moves with the clock; the label up to it is pinned.
    expect(html).toContain(esc(scanFailedStatusLabel("")).trimEnd());
    expect(html).not.toContain(scanStatusLabel(null));
  });

  it("says up to date only while no failure stands", () => {
    stub.lastScanAt = Date.now() - 60_000;
    const html = renderToStaticMarkup(<StatusFooter />);
    expect(html).toContain(scanStatusLabel(null));
    expect(html).not.toContain(esc(scanFailedStatusLabel(null)));
  });
});
