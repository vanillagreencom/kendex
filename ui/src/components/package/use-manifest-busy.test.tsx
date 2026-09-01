import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { Scope } from "@/bindings";
import { useManifestBusy, useVersionsBusy } from "./use-package-data";

// Static rendering reads each store's initial snapshot, so both store hooks
// are wrapped to let a test flip their busy flags.
const stub = vi.hoisted(() => ({
  audit: false,
  updates: false,
  checking: false,
  saving: false,
  settling: [] as { scope: { scope: string; root?: string } }[],
}));
vi.mock("@/stores/updates", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/updates")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useUpdatesStore.getState(),
      busy: stub.updates,
      checking: stub.checking,
      pendingFollows: stub.settling,
    };
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

vi.mock("@/stores/editor", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/editor")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = { ...mod.useEditorStore.getState(), saving: stub.saving };
    return selector ? selector(state) : state;
  };
  return { ...mod, useEditorStore: Object.assign(hook, mod.useEditorStore) };
});

const GLOBAL: Scope = { scope: "global" };
const PROJECT: Scope = { scope: "project", root: "/home/me/app" };

function Probe({ switching, scopes }: { switching: boolean; scopes: Scope[] }) {
  return <span>{useManifestBusy(switching, scopes) ? "busy" : "idle"}</span>;
}

function VersionsProbe() {
  return <span>{useVersionsBusy(false) ? "busy" : "idle"}</span>;
}

const render = (switching: boolean, scopes: Scope[] = [GLOBAL]) =>
  renderToStaticMarkup(<Probe switching={switching} scopes={scopes} />);

// A check builds its report once, so a commit the version controls make
// while it is out would be missing from it and the landing would put the
// rows back. This gate is for the three that stay on screen through a
// check; the Projects tab's Update controls commit the same way but are
// not rendered while one is out. Save, Delete and the toggle write through
// the audit or editor store and take no part in that: gating them on a
// mirror fetch would only cost a save.
describe("useVersionsBusy", () => {
  it("adds a running check, and nothing else does", () => {
    stub.checking = true;
    expect(renderToStaticMarkup(<VersionsProbe />)).toContain("busy");
    expect(render(false)).toContain("idle");
    stub.checking = false;
    expect(renderToStaticMarkup(<VersionsProbe />)).toContain("idle");
  });
});

describe("useManifestBusy", () => {
  it("is one gate over the audit apply, a version switch, updates-store work, and a save", () => {
    expect(render(false)).toContain("idle");
    expect(render(true)).toContain("busy");
    stub.updates = true;
    expect(render(false)).toContain("busy");
    stub.updates = false;
    stub.audit = true;
    expect(render(false)).toContain("busy");
    stub.audit = false;
    stub.saving = true;
    expect(render(false)).toContain("busy");
    stub.saving = false;
  });

  // These controls command the engine directly, outside the updates store's
  // chain, and a flip's apply rewrites the same manifest — two commands that
  // both read it before either applies lose one of the two edits.
  it("holds while a Follow source flip settles in this package's scope", () => {
    stub.settling = [{ scope: { scope: "global" } }];
    expect(render(false, [GLOBAL])).toContain("busy");
    expect(render(false, [PROJECT])).toContain("idle");
    stub.settling = [];
    expect(render(false, [GLOBAL])).toContain("idle");
  });

  // Remove and the enable/disable toggle write every place the package is
  // installed in, not only the one the page was opened at, and a settling
  // flip is rewriting one of those manifests.
  it("holds for a flip in any scope the page's controls write", () => {
    stub.settling = [{ scope: { scope: "project", root: "/home/me/app" } }];
    expect(render(false, [GLOBAL])).toContain("idle");
    expect(render(false, [GLOBAL, PROJECT])).toContain("busy");
    stub.settling = [];
    expect(render(false, [GLOBAL, PROJECT])).toContain("idle");
  });
});
