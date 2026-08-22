import { beforeEach, describe, expect, it } from "vitest";
import type {
  AuditView,
  HarnessId,
  ItemKind,
  ScanResult,
  SourceRow,
} from "@/bindings";
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
      allowUnsafe: [],
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
      harness: "claude",
    })) as AuditView;
    expect(after.drift.some((r) => r.name === "scratch")).toBe(false);
    const read = (await mockInvoke("get_manifest", { scope: acme })) as {
      manifest: { skills?: Record<string, { source: string }> } | null;
    };
    expect(read.manifest?.skills?.scratch?.source).toBe("local");
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
