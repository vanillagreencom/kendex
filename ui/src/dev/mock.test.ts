import { beforeEach, describe, expect, it } from "vitest";
import type {
  AuditView,
  HarnessId,
  ItemKind,
  PackageUpdate_Serialize,
  ReportRouteView,
  ScanResult,
  Scope,
  SourceRow,
} from "@/bindings";
import { showUpdateOutcome } from "@/lib/update-outcome";
import bindingsSource from "../bindings.ts?raw";
import { capabilityTable } from "./caps";
import { ACME } from "./fixtures";
import { handlers, mockInvoke, resetMock } from "./mock";

const BOTH = { project: true, global: true };
const GLOBAL = { project: false, global: true };
const NEITHER = { project: false, global: false };

const acme = { scope: "project", root: ACME } as const;

describe("mock bridge", () => {
  beforeEach(resetMock);

  it("has a handler for every generated command, and no extras", () => {
    const names = [
      ...bindingsSource.matchAll(
        /__TAURI_INVOKE(?:<[\s\S]*?>)?\(\s*"([a-z_]+)"/g,
      ),
    ].map((m) => m[1]);
    expect(names.length).toBeGreaterThan(15);
    expect(Object.keys(handlers).sort()).toEqual([...new Set(names)].sort());
  });

  // The mock stands in for the real command, so its answer has to be the
  // shape the callers read. A bare view here left the update toast
  // mapping over an undefined `heldBack` and threw in the dev harness.
  it("answers a single-package update with what it wrote and what it held", async () => {
    const update = (await mockInvoke("package_update", {
      scope: acme,
      kind: "skill" as ItemKind,
      name: "github",
    })) as PackageUpdate_Serialize;
    expect(Object.keys(update).sort()).toEqual([
      "heldBack",
      "moved",
      "removed",
      "view",
    ]);
    expect(Array.isArray(update.heldBack)).toBe(true);
    expect(Array.isArray(update.removed)).toBe(true);
    expect(Array.isArray(update.moved)).toBe(true);
    expect(update.view.scope).toEqual(acme);
    // The reader the shape is for: it must not throw on this answer.
    expect(() => showUpdateOutcome("github", update)).not.toThrow();
  });

  it("rejects unknown commands with a plain string", async () => {
    await expect(mockInvoke("no_such_command")).rejects.toMatch("no handler");
  });

  it("toggle and apply mutate the shared state", async () => {
    await mockInvoke("toggle_item", {
      scope: acme,
      name: "github",
      enabled: false,
    });
    const scan = (await mockInvoke("scan_machine")) as ScanResult;
    const github = scan.items.filter(
      (i) =>
        i.name === "github" &&
        i.scope.scope === "project" &&
        i.scope.root === ACME,
    );
    expect(github.length).toBeGreaterThan(0);
    expect(github.every((i) => i.enabled === false)).toBe(true);

    const after = (await mockInvoke("apply_plan", {
      scope: acme,
      removeOrphans: false,
    })) as AuditView;
    expect(after.plan).toEqual([]);
    expect(after.drift.map((r) => r.state).sort()).toEqual([
      "orphaned",
      "unmanaged",
    ]);
  });

  it("adopting clears the not-managed row and declares the item", async () => {
    const after = (await mockInvoke("adopt_item", {
      scope: acme,
      kind: "skill",
      name: "scratch",
      harnesses: ["claude"],
    })) as AuditView;
    expect(after.drift.some((r) => r.name === "scratch")).toBe(false);
    const manifest = (await mockInvoke("get_manifest", { scope: acme })) as {
      skills?: Record<string, { source: string }>;
    };
    expect(manifest.skills?.scratch?.source).toBe("local");
  });

  it("blocks removing a source that still provides items", async () => {
    await expect(
      mockInvoke("source_remove", {
        scope: { scope: "global" },
        name: "kendex",
      }),
    ).rejects.toMatch("disable");
    const rows = (await mockInvoke("source_toggle", {
      scope: { scope: "global" },
      name: "kendex",
      enabled: false,
    })) as SourceRow[];
    const row = rows.find(
      (r) => r.scope.scope === "global" && r.name === "kendex",
    );
    expect(row?.enabled).toBe(false);
  });
});

// The dev app must answer the report dialog the way the engine does, or the
// preview tells you a kendex skill belongs to your own project. The engine
// judges the lock, and the mock's stand-in for it is the provenance table:
// an observed item's origin is the git origin of wherever its file sits,
// which for a skill installed by link is the consuming repository.
describe("mock report routing", () => {
  beforeEach(resetMock);

  const globalScope = { scope: "global" } as const;
  const routeOf = async (scope: Scope, name: string, kind: ItemKind | null) =>
    (await mockInvoke("report_route", {
      scope,
      name,
      kind,
    })) as ReportRouteView;

  it("routes a skill recorded from the kendex marketplace to kendex", async () => {
    const route = await routeOf(acme, "github", "skill");
    expect(route.kendexOwned).toBe(true);
    expect(route.repo).toBe("vanillagreencom/kendex");
    expect(route.label).toBe("skills");
  });

  it("keeps a name nothing recorded local, whatever the scan says", async () => {
    // Observed with the upstream as its origin and in no provenance row: a
    // mock reading items would file this against kendex.
    const scan = (await mockInvoke("scan_machine")) as ScanResult;
    expect(
      scan.items.some(
        (it) =>
          it.name === "pi-hooks" && it.origin === "vanillagreencom/kendex",
      ),
    ).toBe(true);
    const route = await routeOf(globalScope, "pi-hooks", "pi-extension");
    expect(route.kendexOwned).toBe(false);
    expect(route.repo).toBe(null);
    expect(route.label).toBe(null);
  });

  it("keeps a fork of a kendex skill local", async () => {
    const route = await routeOf(globalScope, "release-notes", "skill");
    expect(route.kendexOwned).toBe(false);
    expect(route.repo).toBe(null);
  });
});

// The browser mock hand-mirrors crates/core/src/harness/caps.rs. Where it
// drifts, dev mode shows a tool as unmanageable that the app manages.
describe("mock capability table", () => {
  const caps = (harness: HarnessId, kind: ItemKind) =>
    capabilityTable().find((r) => r.harness === harness && r.kind === kind)
      ?.caps;

  it("says Gemini and Copilot are managed where the real table does", () => {
    for (const kind of ["agent", "skill", "command", "hook", "mcp-server"]) {
      expect(caps("gemini", kind as ItemKind)?.install).toEqual(BOTH);
    }
    // Whether a Gemini server is on is recorded once for the whole machine.
    expect(caps("gemini", "mcp-server")?.toggle).toEqual(GLOBAL);
    expect(caps("gemini", "hook")?.enforcement).toBe("enforced");
    // Extensions install in one place through a rules file nobody documents.
    expect(caps("gemini", "plugin")?.install).toEqual(NEITHER);

    for (const kind of ["agent", "skill", "hook", "mcp-server"]) {
      expect(caps("copilot", kind as ItemKind)?.install).toEqual(BOTH);
      expect(caps("copilot", kind as ItemKind)?.toggle).toEqual(BOTH);
    }
    expect(caps("copilot", "hook")?.enforcement).toBe("enforced");

    // Pi hooks are enforced through the pi-hooks carrier.
    expect(caps("pi", "hook")?.install).toEqual(BOTH);
    expect(caps("pi", "hook")?.enforcement).toBe("enforced");
    // Copilot has no file-backed slash commands at all, and installing a
    // plugin needs a marketplace kendex cannot resolve yet.
    expect(caps("copilot", "command")?.observe).toEqual(NEITHER);
    expect(caps("copilot", "plugin")?.install).toEqual(NEITHER);
    expect(caps("copilot", "plugin")?.toggle).toEqual(BOTH);
  });
});
