// Fixture behavior for the package page and Updates page: two versions of
// everything installed from the mock catalog, one pending update, and a
// small file tree with a readme.
import type { ItemKind, Scope, UpdateRow, VersionSel } from "@/bindings";
import { type Handler, same, store, view } from "./mock-state";

const OLD = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const NEW = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

const SKILL_BODY = [
  "---",
  "name: gh",
  "description: Work with GitHub from the terminal.",
  "---",
  "Use the gh CLI for pull requests.",
  "Prefer draft PRs while iterating.",
].join("\n");

const README = "# gh\n\nGitHub flows for coding agents.\n";

function installedItems() {
  return store.state.items.filter(
    (item) => item.origin !== null && item.origin !== "local",
  );
}

function updateRows(): UpdateRow[] {
  return installedItems().map((item, index) => ({
    scope: item.scope,
    kind: item.kind,
    name: item.name,
    source: "kendex",
    repo: item.origin ?? "vanillagreencom/kendex",
    repoIdentity: item.origin ?? "vanillagreencom/kendex",
    current: { commit: OLD, label: "v1.0", date: "2026-08-01T10:00:00Z" },
    latest:
      index === 0
        ? { commit: NEW, label: "v1.1", date: "2026-08-14T10:00:00Z" }
        : { commit: OLD, label: "v1.0", date: "2026-08-01T10:00:00Z" },
    updateAvailable: index === 0,
    pinned: false,
    ignored: store.state.ignored.some(
      (entry) => entry.kind === item.kind && entry.name === item.name,
    ),
    blockedByLocalEdit: false,
    editedHarnesses: [],
    forkableHarness: null,
    forked: false,
    mixed: false,
    removedUpstream: false,
  }));
}

export const packageHandlers: Record<string, Handler> = {
  package_versions: ({ name }: { name: string }) => [
    {
      id: NEW,
      label: "v1.1",
      date: "2026-08-14T10:00:00Z",
      summary: `${name}: sharpen the instructions`,
      installed: false,
      newerThanInstalled: true,
    },
    {
      id: OLD,
      label: "v1.0",
      date: "2026-08-01T10:00:00Z",
      summary: `${name}: first release`,
      installed: true,
      newerThanInstalled: false,
    },
  ],
  updates_overview: () => ({ rows: updateRows(), warnings: [] }),
  updates_refresh: () => ({ rows: updateRows(), warnings: [] }),
  update_set_ignored: ({
    kind,
    name,
    ignored,
  }: {
    kind: ItemKind;
    name: string;
    ignored: boolean;
  }) => {
    store.state.ignored = store.state.ignored.filter(
      (entry) => !(entry.kind === kind && entry.name === name),
    );
    if (ignored) store.state.ignored.push({ kind, name });
    return { rows: updateRows(), warnings: [] };
  },
  package_set_rev: ({ scope }: { scope: Scope }) => view(scope),
  package_diff: ({ from, to }: { from: VersionSel; to: VersionSel }) => ({
    files: [
      {
        path: "SKILL.md",
        status: "modified",
        additions: 2,
        deletions: 1,
        lossy: false,
        hunks: [
          {
            header: "@@ -4,3 +4,4 @@",
            lines: [
              { kind: "context", text: "---", oldNo: 4, newNo: 4 },
              {
                kind: "remove",
                text: "Use the gh CLI for pull requests.",
                oldNo: 5,
                newNo: null,
              },
              {
                kind: "add",
                text: "Use the gh CLI for pull requests and issues.",
                oldNo: null,
                newNo: 5,
              },
              {
                kind: "add",
                text: "Link issues from every PR description.",
                oldNo: null,
                newNo: 6,
              },
              {
                kind: "context",
                text: "Prefer draft PRs while iterating.",
                oldNo: 6,
                newNo: 7,
              },
            ],
          },
        ],
      },
      {
        path: "references/tips.md",
        status: "added",
        additions: 3,
        deletions: 0,
        lossy: false,
        hunks: [
          {
            header: "@@ -0,0 +1,3 @@",
            lines: [
              { kind: "add", text: "# Tips", oldNo: null, newNo: 1 },
              { kind: "add", text: "", oldNo: null, newNo: 2 },
              {
                kind: "add",
                text: "Review before merge.",
                oldNo: null,
                newNo: 3,
              },
            ],
          },
        ],
      },
    ],
    totalAdditions: 5,
    totalDeletions: 1,
    truncated: false,
    _from: from,
    _to: to,
  }),
  package_fork: ({
    scope,
    kind,
    name,
  }: {
    scope: Scope;
    kind: ItemKind;
    name: string;
  }) => {
    for (const item of store.state.items) {
      if (same(item.scope, scope) && item.kind === kind && item.name === name) {
        item.origin = "local";
      }
    }
    return view(scope);
  },
  fork_rename: ({ scope }: { scope: Scope }) => view(scope),
  apply_discard_edits: ({
    scope,
  }: {
    scope: Scope;
    kind: ItemKind;
    name: string;
  }) => view(scope),
  package_files: () => [
    { path: "README.md", size: README.length, isReadme: true },
    { path: "SKILL.md", size: SKILL_BODY.length, isReadme: false },
    { path: "references/tips.md", size: 42, isReadme: false },
  ],
  package_file: ({ name, path }: { name: string; path: string }) => ({
    path: `/mock/skills/${name}/${path}`,
    content: path.endsWith("README.md") ? README : SKILL_BODY,
    truncated: false,
  }),
  package_readme: ({ name }: { name: string }) => ({
    path: `/mock/skills/${name}/README.md`,
    content: README,
    truncated: false,
  }),
  package_meta: ({ name }: { name: string }) => ({
    source: "kendex",
    repo: "vanillagreencom/kendex",
    repoIdentity: "vanillagreencom/kendex",
    repoUrl: "https://github.com/vanillagreencom/kendex",
    rev: null,
    current: { commit: OLD, label: "v1.0", date: "2026-08-01T10:00:00Z" },
    installedAt: "2026-08-01T10:05:00Z",
    harnesses: ["claude"],
    enabled: true,
    fork: null,
    catalog: {
      version: "1.0.0",
      description: `About ${name}.`,
      author: "vanillagreen",
      license: "MIT",
      homepage: "https://github.com/vanillagreencom/kendex",
      category: null,
    },
  }),
};
