import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { useManifestBusy } from "./use-package-data";

// Static rendering reads each store's initial snapshot, so both store hooks
// are wrapped to let a test flip their busy flags.
const stub = vi.hoisted(() => ({
  audit: false,
  updates: false,
  market: false,
  settings: false,
  saving: false,
}));
vi.mock("@/stores/updates", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/updates")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = { ...mod.useUpdatesStore.getState(), busy: stub.updates };
    return selector ? selector(state) : state;
  };
  return { ...mod, useUpdatesStore: Object.assign(hook, mod.useUpdatesStore) };
});
vi.mock("@/stores/audit", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/audit")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = { ...mod.useAuditStore.getState(), busy: stub.audit };
    return selector ? selector(state) : state;
  };
  return { ...mod, useAuditStore: Object.assign(hook, mod.useAuditStore) };
});

vi.mock("@/stores/marketplaces", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/marketplaces")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = { ...mod.useMarketplacesStore.getState(), busy: stub.market };
    return selector ? selector(state) : state;
  };
  return {
    ...mod,
    useMarketplacesStore: Object.assign(hook, mod.useMarketplacesStore),
  };
});
vi.mock("@/stores/settings", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/settings")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = { ...mod.useSettingsStore.getState(), busy: stub.settings };
    return selector ? selector(state) : state;
  };
  return {
    ...mod,
    useSettingsStore: Object.assign(hook, mod.useSettingsStore),
  };
});

vi.mock("@/stores/editor", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/editor")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = { ...mod.useEditorStore.getState(), saving: stub.saving };
    return selector ? selector(state) : state;
  };
  return { ...mod, useEditorStore: Object.assign(hook, mod.useEditorStore) };
});

function Probe() {
  return <span>{useManifestBusy() ? "busy" : "idle"}</span>;
}

const render = () => renderToStaticMarkup(<Probe />);

// Every writer of a place's kendex.toml is one of these, and a version
// switch is among them. The flag has to live in the store rather than be
// passed down from the page: read from a page, it stops counting the
// moment that page unmounts, and the Save bar comes back up mid-write.
describe("useManifestBusy", () => {
  it("is one gate over every store that rewrites the file", () => {
    expect(render()).toContain("idle");
    for (const flag of [
      "updates",
      "audit",
      "market",
      "settings",
      "saving",
    ] as const) {
      stub[flag] = true;
      expect(render(), `${flag} must hold the gate`).toContain("busy");
      stub[flag] = false;
    }
    expect(render()).toContain("idle");
  });
});
