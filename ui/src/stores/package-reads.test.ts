import { beforeEach, describe, expect, it, vi } from "vitest";
import type { PackageMeta_Serialize, Scope } from "@/bindings";
import { commands } from "@/bindings";
import type { PackageRef } from "./nav";
import {
  ensurePackage,
  type PackageInputs,
  packageReadKey,
  readPackage,
  usePackageReads,
} from "./package-reads";
import { retainedReads } from "./retained-reads";

vi.mock("@/bindings", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: {
    packageMeta: vi.fn(),
    packageFiles: vi.fn(),
    packageReadme: vi.fn(),
    packageVersions: vi.fn(),
  },
}));

const VG: Scope = { scope: "project", root: "/work/vg" };
const HYPR: Scope = { scope: "project", root: "/work/hyprtrade" };
const AT_VG: PackageRef = {
  kind: "skill",
  name: "gh",
  scope: VG,
  identity: "recorded",
};
const INPUTS: PackageInputs = { commit: "a".repeat(40), written: "" };

const record = (source: string): PackageMeta_Serialize => ({
  source,
  repo: "o/r",
  repoUrl: null,
  rev: null,
  current: null,
  installedAt: null,
  harnesses: ["claude"],
  enabled: true,
  fork: null,
  catalog: null,
  support: { state: "read", unsupported: [], advisory: [], fallback: [] },
});

const held = (ref: PackageRef) =>
  usePackageReads.getState().answers[packageReadKey(ref)];

/** Every read lands at once, so a case reads the store straight after. */
const drain = () => new Promise((resolve) => setTimeout(resolve, 0));

beforeEach(() => {
  vi.clearAllMocks();
  usePackageReads.setState({ answers: {} });
  vi.mocked(commands.packageMeta).mockResolvedValue({
    status: "ok",
    data: record("cat"),
  });
  vi.mocked(commands.packageFiles).mockResolvedValue({
    status: "ok",
    data: [],
  });
  vi.mocked(commands.packageReadme).mockResolvedValue({
    status: "ok",
    data: null,
  });
  vi.mocked(commands.packageVersions).mockResolvedValue({
    status: "ok",
    data: [],
  });
});

// The page's address is its whole identity. A package recorded in one
// place, the same package in another place, and an installation nothing
// recorded that wears its kind and name are three answers, and none is
// served from another's read.
describe("which reads a package answer is kept under", () => {
  it.each([
    {
      name: "the same package in another place",
      other: { ...AT_VG, scope: HYPR } as PackageRef,
      asks: 1,
      meta: "cat",
    },
    {
      name: "an installation nothing recorded with the same kind and name",
      other: {
        ...AT_VG,
        identity: "observed",
        at: "/work/vg/.claude/skills/gh",
      } as PackageRef,
      asks: 0,
      meta: null,
    },
  ])("$name", async (row) => {
    ensurePackage(AT_VG, INPUTS);
    await drain();
    vi.mocked(commands.packageMeta).mockClear();

    ensurePackage(row.other, INPUTS);
    await drain();

    expect(
      {
        asks: vi.mocked(commands.packageMeta).mock.calls.length,
        scope: vi.mocked(commands.packageMeta).mock.calls[0]?.[0] ?? null,
        meta: held(row.other)?.meta?.source ?? null,
        kept: held(AT_VG)?.meta?.source,
      },
      row.name,
    ).toEqual({
      asks: row.asks,
      scope: row.asks > 0 ? row.other.scope : null,
      meta: row.meta,
      kept: "cat",
    });
  });
});

// A read that was out when its answer stopped being current lands after
// the read that replaced it. Whichever way the newer one went, the older
// one writes nothing: a late success would put back a record that enables
// Update over a failure, and a late failure would hide a newer answer.
describe("an answer that lands after the read replacing it", () => {
  it.each([
    { name: "newer read landed", newer: "ok" as const, record: "landed" },
    { name: "newer read failed", newer: "failed" as const, record: "failed" },
  ])("$name", async (row) => {
    let late: () => void = () => {};
    vi.mocked(commands.packageMeta).mockReturnValueOnce(
      new Promise((resolve) => {
        late = () => resolve({ status: "ok", data: record("before") });
      }),
    );
    ensurePackage(AT_VG, INPUTS);
    retainedReads.moved();
    vi.mocked(commands.packageMeta).mockResolvedValueOnce(
      row.newer === "ok"
        ? { status: "ok", data: record("after") }
        : { status: "error", error: "REFUSED" },
    );
    ensurePackage(AT_VG, INPUTS);
    await drain();
    late();
    await drain();

    const answer = held(AT_VG);
    expect(
      {
        meta: answer?.meta?.source ?? null,
        record: answer?.reads.record.status,
        reading: answer?.reads.reading,
      },
      row.name,
    ).toEqual({
      meta: row.newer === "ok" ? "after" : null,
      record: row.record,
      reading: false,
    });
  });

  // The page's own Try again keeps the last answer on screen while it runs;
  // a fresh read after an answer stopped being current starts from nothing,
  // so the kept record never stands while its replacement is out.
  it.each([
    { name: "Try again keeps", from: "kept" as const, meta: "cat" },
    { name: "a fresh read clears", from: "afresh" as const, meta: null },
  ])("$name the record while the read is out", async (row) => {
    ensurePackage(AT_VG, INPUTS);
    await drain();
    vi.mocked(commands.packageMeta).mockReturnValueOnce(new Promise(() => {}));

    readPackage(AT_VG, INPUTS, row.from);

    expect(held(AT_VG)?.meta?.source ?? null, row.name).toBe(row.meta);
    expect(held(AT_VG)?.reads.reading).toBe(true);
  });
});
