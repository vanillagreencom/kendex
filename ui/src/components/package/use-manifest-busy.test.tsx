import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { useManifestBusy } from "./use-package-data";

// Static rendering reads each store's initial snapshot, so both store hooks
// are wrapped to let a test flip their busy flags.
const stub = vi.hoisted(() => ({ audit: false, updates: false }));
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

function Probe({ switching }: { switching: boolean }) {
  return <span>{useManifestBusy(switching) ? "busy" : "idle"}</span>;
}

const render = (switching: boolean) =>
  renderToStaticMarkup(<Probe switching={switching} />);

describe("useManifestBusy", () => {
  it("is one gate over the audit apply, a version switch, and updates-store work", () => {
    expect(render(false)).toContain("idle");
    expect(render(true)).toContain("busy");
    stub.updates = true;
    expect(render(false)).toContain("busy");
    stub.updates = false;
    stub.audit = true;
    expect(render(false)).toContain("busy");
    stub.audit = false;
  });
});
