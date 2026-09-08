import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
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
beforeEach(() => {
  Object.assign(stub, {
    audit: false,
    updates: false,
    checking: false,
    saving: false,
    settling: [],
  });
});

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
  it("holds each manifest writer independently", () => {
    const rows = [
      {
        name: "idle",
        switching: false,
        audit: false,
        updates: false,
        saving: false,
        expected: "idle",
      },
      {
        name: "version switch",
        switching: true,
        audit: false,
        updates: false,
        saving: false,
        expected: "busy",
      },
      {
        name: "updates work",
        switching: false,
        audit: false,
        updates: true,
        saving: false,
        expected: "busy",
      },
      {
        name: "audit apply",
        switching: false,
        audit: true,
        updates: false,
        saving: false,
        expected: "busy",
      },
      {
        name: "editor save",
        switching: false,
        audit: false,
        updates: false,
        saving: true,
        expected: "busy",
      },
    ];
    expect(rows).toHaveLength(5);
    for (const entry of rows) {
      Object.assign(stub, {
        audit: entry.audit,
        updates: entry.updates,
        saving: entry.saving,
      });
      expect(render(entry.switching), entry.name).toBe(
        `<span>${entry.expected}</span>`,
      );
    }
  });

  it("holds only while a flip settles in any scope the controls write", () => {
    const rows = [
      {
        name: "same scope",
        settling: [GLOBAL],
        scopes: [GLOBAL],
        expected: "busy",
      },
      {
        name: "other scope",
        settling: [GLOBAL],
        scopes: [PROJECT],
        expected: "idle",
      },
      {
        name: "global flip cleared",
        settling: [],
        scopes: [GLOBAL],
        expected: "idle",
      },
      {
        name: "project flip outside write scopes",
        settling: [PROJECT],
        scopes: [GLOBAL],
        expected: "idle",
      },
      {
        name: "project among write scopes",
        settling: [PROJECT],
        scopes: [GLOBAL, PROJECT],
        expected: "busy",
      },
      {
        name: "project flip cleared",
        settling: [],
        scopes: [GLOBAL, PROJECT],
        expected: "idle",
      },
    ];
    expect(rows).toHaveLength(6);
    for (const entry of rows) {
      stub.settling = entry.settling.map((scope) => ({ scope }));
      expect(render(false, entry.scopes), entry.name).toBe(
        `<span>${entry.expected}</span>`,
      );
    }
  });
});
