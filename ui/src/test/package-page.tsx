// The package page's test harness: the places, the records, the mount, and
// the reset, shared by the files that exercise the page.
//
// Each test file installs its own `vi.mock("@/bindings", ...)`; the helpers
// here read through whichever mock the importing file set up, so a file
// stubs the commands its own subject calls and no more.
import { vi } from "vitest";
import type {
  ItemKind,
  Manifest_Serialize,
  ObservedItem,
  PackageMeta_Serialize,
  Scope,
  UpdateRow,
} from "@/bindings";
import { commands } from "@/bindings";
import { READ_LANDED } from "@/lib/read-state";
import { scopeKey } from "@/lib/scope";
import { PackagePage } from "@/pages/package";
import { useAuditStore } from "@/stores/audit";
import { useEditorStore } from "@/stores/editor";
import { useNavStore } from "@/stores/nav";
import type { PackageView } from "@/stores/nav-types";
import { useScanStore } from "@/stores/scan";
import { useUpdatesStore } from "@/stores/updates";
import { mount, settle } from "@/test/dom";

export type Project = Extract<Scope, { scope: "project" }>;
export const VG: Project = { scope: "project", root: "/work/vg" };
export const HYPR: Project = { scope: "project", root: "/work/hyprtrade" };

export const installedAt = (
  scope: Project,
  kind: ItemKind = "skill",
): ObservedItem => ({
  kind,
  name: "gh",
  scope,
  harness: "claude",
  path: `${scope.root}/.claude/skills/gh`,
  fileState: { state: "file" },
  enabled: true,
  origin: null,
  description: "about gh",
  tags: [],
  modifiedAt: null,
  vendor: null,
});

export const PLAIN: Manifest_Serialize = { schema: 1, install: {} };
export const CUSTOMIZED: Manifest_Serialize = {
  schema: 1,
  install: {},
  "skill-instructions": { gh: "mine" },
};

export const nothing = { status: "error" as const, error: "not in this test" };

/** Mount the page about `gh` at `here`, with the package installed in
 *  every place of `installed` and each place's manifest as given. */
export const openPage = async (
  here: Project,
  installed: Project[],
  manifests: Record<string, Manifest_Serialize>,
  /** What the page opens showing. An Updates-row Preview hands it a
   *  comparison, so the page starts on a diff rather than on its files. */
  packageView: PackageView | null = null,
  /** The package's kind. Only the kinds a manifest overlays get a
   *  Customize tab; every kind gets the rest of the strip. */
  kind: ItemKind = "skill",
) => {
  vi.mocked(commands.getManifest).mockImplementation((scope) =>
    Promise.resolve({
      status: "ok",
      data: { manifest: manifests[scopeKey(scope)] ?? null, base: null },
    }),
  );
  useScanStore.setState({
    result: {
      harnesses: [],
      items: installed.map((scope) => installedAt(scope, kind)),
      missingProjects: [],
      warnings: [],
    },
  });
  useNavStore.setState({
    page: "package",
    packageRef: { kind, name: "gh", scope: here },
    packageView,
  });
  const host = mount(<PackagePage />);
  // The page points the editor at its own place on mount, and that read
  // has to land before the editor can be pointed anywhere else.
  await settle();
  return host;
};

export const header = (host: HTMLElement) =>
  host.querySelector("header")?.textContent;

/** What the Updates read says about gh in one place: nothing hand-edited
 *  and nothing forked. Without a row a place's hand-edit state is unread,
 *  and the mark counts only places somebody has looked at. */
export const updateRow = (scope: Project): UpdateRow => ({
  scope,
  kind: "skill",
  name: "gh",
  source: "cat",
  repo: "o/r",
  repoIdentity: "o/r",
  current: null,
  latest: null,
  updateAvailable: false,
  pinned: false,
  holdOwner: null,
  ignored: false,
  blockedByLocalEdit: false,
  editedHarnesses: [],
  forkableHarness: null,
  canDiscard: false,
  canTakeLatest: false,
  derived: false,
  requiredBy: [],
  forked: false,
  mixed: false,
  removedUpstream: false,
  noPerPackageUpdate: null,
});

/** The place's own record, as the page reads it: a following package with
 *  nothing held and nothing forked. */
export const RECORD: PackageMeta_Serialize = {
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

/** The backend answering nothing and every store back at its opening
 *  state, for a file's own `beforeEach`. */
export const resetPage = () => {
  vi.clearAllMocks();
  // clearAllMocks leaves implementations standing, and a test that
  // answers the audit would otherwise answer it for every test after
  // it in this file. The default is an audit that ran and found nothing
  // to say about this package: a check that never answers is a state the
  // safety tab reports, so a test must ask for it rather than inherit it.
  vi.mocked(commands.auditAll).mockReset();
  vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
  vi.mocked(commands.packageMeta).mockResolvedValue(nothing);
  vi.mocked(commands.packageFiles).mockResolvedValue(nothing);
  vi.mocked(commands.packageVersions).mockResolvedValue(nothing);
  vi.mocked(commands.packageReadme).mockResolvedValue(nothing);
  vi.mocked(commands.editorInventory).mockResolvedValue(nothing);
  // Every place read and holding no settings value off a default, so the
  // manifest is what decides the header's mark.
  vi.mocked(commands.getScopeSettings).mockResolvedValue({
    status: "ok",
    data: { applies: true, skills: [], base: null },
  });
  vi.mocked(commands.libraryProvenance).mockResolvedValue(nothing);
  vi.mocked(commands.packageDiff).mockResolvedValue(nothing);
  vi.mocked(commands.revealPath).mockResolvedValue({
    status: "ok",
    data: null,
  });
  vi.mocked(commands.openInEditor).mockResolvedValue({
    status: "ok",
    data: null,
  });
  useEditorStore.setState({
    scope: { scope: "global" },
    draft: null,
    base: null,
    saved: {},
    settings: null,
    settingsEdits: [],
    savedSettings: {},
    dirty: false,
    manifestDirty: false,
  });
  useUpdatesStore.setState({
    rows: [],
    read: READ_LANDED,
    checking: false,
    pendingFollows: [],
  });
  useAuditStore.setState({
    views: [],
    auditedAt: null,
    read: READ_LANDED,
  });
};
