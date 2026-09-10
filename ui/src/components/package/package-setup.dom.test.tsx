// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type {
  Ask,
  ObservedItem,
  PackageMeta_Serialize,
  PackageSetup,
  ProvenanceRow,
  Scope,
  SetupState,
} from "@/bindings";
import { commands } from "@/bindings";
import {
  ACTIVATE_LABEL,
  CHECK_AGAIN_LABEL,
  REPAIR_LABEL,
  SETUP_ACTIVE,
  SETUP_NOT_ACTIVE,
  setupHeading,
} from "@/lib/copy-setup";
import { READ_LANDED, READ_PENDING } from "@/lib/read-state";
import { scopeKey } from "@/lib/scope";
import { useAuditStore } from "@/stores/audit";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { usePackageSetupStore } from "@/stores/package-setup";
import { useProvenanceStore } from "@/stores/provenance";
import { useScanStore } from "@/stores/scan";
import { useUpdatesStore } from "@/stores/updates";
import { mount, settle } from "@/test/dom";
import { PackageProjects } from "./package-projects";
import { usePackageSetupRead } from "./use-package-setup";

vi.mock("@/bindings", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: {
    packageMeta: vi.fn(),
    libraryProvenance: vi.fn(),
    packageSetup: vi.fn(),
  },
}));

const VG: Scope = { scope: "project", root: "/work/vg" };
const HYPR: Scope = { scope: "project", root: "/work/hyprtrade" };
const PERSONAL: Scope = { scope: "global" };

const install = (scope: Scope): ObservedItem => ({
  kind: "skill",
  name: "commit-guards",
  harness: "claude",
  scope,
  path: "/x/claude",
  fileState: { state: "file" },
  enabled: true,
  origin: null,
  description: null,
  tags: [],
  modifiedAt: null,
  vendor: null,
});

const owned = (scope: Scope): ProvenanceRow => ({
  scope,
  kind: "skill",
  name: "commit-guards",
  harness: "claude",
  origin: { origin: "marketplace", source: "cat", repo: "o/r" },
});

const META: PackageMeta_Serialize = {
  source: "cat",
  repo: "o/r",
  repoUrl: null,
  rev: null,
  current: null,
  installedAt: null,
  harnesses: ["claude"],
  enabled: true,
  fork: null,
  catalog: null,
};

/** One place's answer, as the command gives it. `declares` false is the
 *  ordinary package: it says nothing about the repository, so there is no
 *  setup row anywhere. */
const answer = (
  state: SetupState,
  over: Partial<PackageSetup["status"]> = {},
): PackageSetup => ({
  status: {
    state,
    said: [],
    canApply: state !== "notDeclared",
    canCheck: state !== "notDeclared" && state !== "unavailable",
    shared: state !== "notDeclared",
    ...over,
  },
  disclosure:
    state === "notDeclared"
      ? null
      : {
          declared: {
            name: "commit-guards",
            root: "/work/vg/.agents/skills/commit-guards",
            summary: "Arms git hooks.",
            writes: [],
            installer: "scripts/install-git-hooks",
            uninstaller: null,
            checker: null,
            removal: null,
            notes: [],
            companions: [],
          },
          name: "commit-guards",
          summary: "Arms git hooks.",
          writes: [],
          companions: [],
          notes: [],
          undo: null,
        },
});

/** What the command answers with, per place. */
/** Every scope the command was asked about, and how it was asked. */
const asked = (): [Scope, Ask][] =>
  vi
    .mocked(commands.packageSetup)
    .mock.calls.map(([scope, , ask]) => [scope, ask]);

const setupSays = (per: (scope: Scope) => PackageSetup) =>
  vi
    .mocked(commands.packageSetup)
    .mockImplementation((scope) =>
      Promise.resolve({ status: "ok", data: per(scope) }),
    );

/** The page as `package-tabs.tsx` composes it: the read is started once
 *  above the tabs, and the Projects tab draws from what it answered. A
 *  status can mean running the package's own script, so where the read is
 *  started is part of the behaviour and the harness keeps it there. */
function Page({ scopes }: { scopes: Scope[] }) {
  usePackageSetupRead("commit-guards", scopes);
  return (
    <PackageProjects
      kind="skill"
      name="commit-guards"
      scopes={scopes}
      busy={false}
      focus={null}
      onDelete={() => {}}
    />
  );
}

const openTab = async (scopes: Scope[]) => {
  const host = mount(<Page scopes={scopes} />);
  await settle();
  return host;
};

const buttonNamed = (host: HTMLElement, label: string, nth = 0) => {
  const found = Array.from(host.querySelectorAll("button")).filter(
    (one) => one.textContent === label,
  )[nth];
  if (!found) throw new Error(`no "${label}" button at index ${nth}`);
  return found;
};

beforeEach(() => {
  usePackageSetupStore.setState({ entries: {} });
  useAuditStore.setState({ removeItem: vi.fn(), busy: false });
  useUpdatesStore.setState({
    rows: [],
    read: READ_LANDED,
    checking: false,
    updateOne: vi.fn(),
    updateRows: vi.fn(),
  });
  useProvenanceStore.setState({
    rows: [],
    loaded: false,
    read: READ_PENDING,
    reading: false,
  });
  useMarketplacesStore.setState({ pendingEffects: null, rows: [] });
  vi.mocked(commands.libraryProvenance).mockResolvedValue({
    status: "ok",
    data: [owned(VG), owned(HYPR)],
  });
  vi.mocked(commands.packageMeta).mockResolvedValue({
    status: "ok",
    data: META,
  });
  useScanStore.setState({
    result: {
      harnesses: [],
      items: [install(VG), install(HYPR)],
      missingProjects: [],
      warnings: [],
    },
  });
});

afterEach(() => {
  vi.restoreAllMocks();
});

/** The Projects tab's second fact about each place: installed is one
 *  thing, set up is another, and the tab has to be able to say they
 *  differ. */
describe("setup on the Projects tab", () => {
  it("draws no setup row for a package that changes nothing about the repository", async () => {
    setupSays(() => answer("notDeclared"));
    const host = await openTab([VG]);
    expect(host.textContent).not.toContain(setupHeading("vg"));
  });

  it("draws no setup row when no place could answer", async () => {
    vi.mocked(commands.packageSetup).mockResolvedValue({
      status: "error",
      error: "the lock would not read",
    });
    const host = await openTab([VG]);
    expect(host.textContent).not.toContain(setupHeading("vg"));
  });

  it("reports each project on its own, from that project's own answer", async () => {
    setupSays((scope) =>
      scopeKey(scope) === scopeKey(VG) ? answer("active") : answer("notActive"),
    );
    const host = await openTab([VG, HYPR]);
    expect(host.textContent).toContain(SETUP_ACTIVE);
    expect(host.textContent).toContain(SETUP_NOT_ACTIVE);
    // The project that is already set up is not offered a second one.
    expect(
      Array.from(host.querySelectorAll("button")).filter(
        (one) => one.textContent === ACTIVATE_LABEL,
      ),
    ).toHaveLength(1);
  });

  it("asks the repository-changes dialog for the yes, in the project pressed", async () => {
    setupSays(() => answer("notActive"));
    const host = await openTab([VG, HYPR]);

    await userEvent.click(buttonNamed(host, ACTIVATE_LABEL, 1));

    const pending = useMarketplacesStore.getState().pendingEffects;
    expect(pending?.queue).toHaveLength(1);
    expect(pending?.queue[0]?.scope).toEqual(HYPR);
    expect(pending?.queue[0]?.disclosure.name).toBe("commit-guards");
  });

  it("repairs a damaged setup through the same dialog", async () => {
    setupSays(() => answer("needsRepair"));
    const host = await openTab([VG]);

    await userEvent.click(buttonNamed(host, REPAIR_LABEL));

    expect(
      useMarketplacesStore.getState().pendingEffects?.queue[0]?.scope,
    ).toEqual(VG);
  });

  it("asks nothing about the personal place and draws it no setup row", async () => {
    // A personal install writes into the tool directories and changes no
    // repository, so there is nothing there to be set up. Decided before a
    // status is taken, not after: asking returned a state the card then had
    // to word.
    useScanStore.setState({
      result: {
        harnesses: [],
        items: [install(VG), install(PERSONAL)],
        missingProjects: [],
        warnings: [],
      },
    });
    vi.mocked(commands.libraryProvenance).mockResolvedValue({
      status: "ok",
      data: [owned(VG), owned(PERSONAL)],
    });
    setupSays(() => answer("notActive"));

    const host = await openTab([VG, PERSONAL]);

    // The effect re-runs across renders, so what matters is which places
    // were named at all, not how many times.
    expect(asked().map(([scope]) => scopeKey(scope))).not.toContain(
      scopeKey(PERSONAL),
    );
    expect(asked().map(([scope]) => scopeKey(scope))).toContain(scopeKey(VG));
    expect(
      Array.from(host.querySelectorAll("button")).filter(
        (one) => one.textContent === ACTIVATE_LABEL,
      ),
    ).toHaveLength(1);
    expect(host.textContent).not.toContain(setupHeading("User level"));
  });

  it("asks as a surface on open and as a person on Check again", async () => {
    // The backend runs the package's own script only under a licence, and
    // somebody pressing the control is one. A page drawing itself is not.
    setupSays(() => answer("notActive"));
    const host = await openTab([VG]);
    expect(asked().map(([, ask]) => ask)).not.toContain("person");

    await userEvent.click(buttonNamed(host, CHECK_AGAIN_LABEL));
    await settle();

    expect(asked().at(-1)).toEqual([VG, "person"]);
  });

  it("prints the cause when a place's command refuses", async () => {
    vi.mocked(commands.packageSetup).mockImplementation((scope) =>
      Promise.resolve(
        scopeKey(scope) === scopeKey(VG)
          ? { status: "ok", data: answer("active") }
          : { status: "error", error: "its declaration will not read" },
      ),
    );

    const host = await openTab([VG, HYPR]);

    expect(host.textContent).toContain("its declaration will not read");
  });

  it("reads the repository again when Check again is pressed", async () => {
    setupSays(() => answer("notActive"));
    const host = await openTab([VG]);
    const before = vi.mocked(commands.packageSetup).mock.calls.length;

    await userEvent.click(buttonNamed(host, CHECK_AGAIN_LABEL));
    await settle();

    expect(vi.mocked(commands.packageSetup).mock.calls.length).toBe(before + 1);
  });

  it("reads the repository again once the dialog has been answered for", async () => {
    setupSays(() => answer("notActive"));
    const host = await openTab([VG]);
    await userEvent.click(buttonNamed(host, ACTIVATE_LABEL));
    const before = vi.mocked(commands.packageSetup).mock.calls.length;

    // Whatever the answer was: what says the effect is in force is the
    // check, never the run's own exit.
    setupSays(() => answer("active"));
    useMarketplacesStore.setState({ pendingEffects: null });
    await settle();

    expect(vi.mocked(commands.packageSetup).mock.calls.length).toBe(before + 1);
    expect(host.textContent).toContain(SETUP_ACTIVE);
  });
});
