import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { observedItem } from "@/lib/observed-test-item";
import { useEditorStore } from "@/stores/editor";
import { PackagePage } from "./package";

const VG = { scope: "project", root: "/work/vg" } as const;
const HYPR = { scope: "project", root: "/work/hyprtrade" } as const;

// The page's children are mocked to hand back the props they were given.
// What is pinned here is the page's own destructure, not the helper behind
// it: a test of the helper alone passes whether or not the page still asks
// it the right question, and asking the wrong one is how the page comes to
// describe a place the reader never opened.
const seen = vi.hoisted(() => ({
  body: null as Record<string, unknown> | null,
  header: null as Record<string, unknown> | null,
  actions: null as Record<string, unknown> | null,
}));
vi.mock("@/components/package/package-body", () => ({
  PackageBody: (props: Record<string, unknown>) => {
    seen.body = props;
    return null;
  },
}));
vi.mock("@/components/package/package-header", () => ({
  PackageHeader: (props: Record<string, unknown>) => {
    seen.header = props;
    return props.action as never;
  },
}));
vi.mock("@/components/package/package-actions", () => ({
  PackageActions: (props: Record<string, unknown>) => {
    seen.actions = props;
    return null;
  },
}));
vi.mock("@/components/customize/item-customize", () => ({
  ItemCustomize: () => null,
}));
vi.mock("@/components/marks-note", () => ({ MarksNote: () => null }));
vi.mock("@/components/package/remove-dialog", () => ({
  RemoveDialog: () => null,
}));

const stub = vi.hoisted(() => ({
  scope: { scope: "project", root: "/work/vg" } as unknown,
  editorScope: { scope: "project", root: "/work/hyprtrade" } as unknown,
  rows: [] as unknown[],
  saved: {} as Record<string, unknown>,
  held: {} as Record<string, unknown>,
  // Enough for the Update button to be offered: a newer version exists and
  // the package's own record was read.
  meta: null as unknown,
  versions: [] as unknown[],
  toggled: [] as unknown[],
}));

vi.mock("@/components/package/use-package-data", async (importOriginal) => {
  const mod =
    await importOriginal<
      typeof import("@/components/package/use-package-data")
    >();
  return {
    ...mod,
    usePackageData: () => ({
      meta: stub.meta,
      files: [],
      versions: stub.versions,
      load: () => {},
    }),
    usePackageDiff: () => null,
    useManifestBusy: () => false,
  };
});

vi.mock("@/stores/nav", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/nav")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useNavStore.getState(),
      packageRef: { kind: "skill", name: "gh", scope: stub.scope },
      packageView: null,
      clearPackageView: () => {},
      back: () => {},
    };
    return selector ? selector(state) : state;
  };
  return { ...mod, useNavStore: Object.assign(hook, mod.useNavStore) };
});

vi.mock("@/stores/scan", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/scan")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useScanStore.getState(),
      result: {
        items: [
          observedItem({ name: "gh", scope: VG, path: "/work/vg/gh" }),
          observedItem({ name: "gh", scope: HYPR, path: "/work/hyprtrade/gh" }),
        ],
      },
    };
    return selector ? selector(state) : state;
  };
  return { ...mod, useScanStore: Object.assign(hook, mod.useScanStore) };
});

vi.mock("@/stores/audit", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/audit")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useAuditStore.getState(),
      busy: false,
      toggle: async (scope: unknown) => {
        stub.toggled.push(scope);
      },
    };
    return selector ? selector(state) : state;
  };
  return { ...mod, useAuditStore: Object.assign(hook, mod.useAuditStore) };
});

vi.mock("@/stores/editor", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/editor")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useEditorStore.getState(),
      scope: stub.editorScope,
      draft: null,
      saved: stub.saved,
      held: stub.held,
      saving: false,
      manifestsLoaded: true,
      manifestError: null,
      openScope: async () => {},
    };
    return selector ? selector(state) : state;
  };
  return { ...mod, useEditorStore: Object.assign(hook, mod.useEditorStore) };
});

vi.mock("@/stores/updates", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/updates")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useUpdatesStore.getState(),
      rows: stub.rows,
      loaded: true,
      error: null,
    };
    return selector ? selector(state) : state;
  };
  return { ...mod, useUpdatesStore: Object.assign(hook, mod.useUpdatesStore) };
});

const render = () => {
  renderToStaticMarkup(<PackagePage />);
  if (!seen.body || !seen.header || !seen.actions)
    throw new Error("the page rendered without its body, header or actions");
  return { body: seen.body, header: seen.header, actions: seen.actions };
};

beforeEach(() => {
  seen.body = null;
  seen.header = null;
  seen.actions = null;
  stub.scope = VG;
  stub.editorScope = HYPR;
  stub.rows = [];
  stub.saved = { "/work/vg": {}, "/work/hyprtrade": {} };
  stub.held = {};
  stub.meta = { rev: null, fork: null };
  stub.versions = [
    {
      id: "b".repeat(40),
      label: "v2",
      date: "2026-08-01",
      summary: "newer",
      installed: false,
      newerThanInstalled: true,
    },
    {
      id: "a".repeat(40),
      label: "v1",
      date: "2026-07-01",
      summary: "installed",
      installed: true,
      newerThanInstalled: false,
    },
  ];
});

// One click means every place this package is installed in. A refusal
// partway through the loop would leave it changed in some projects and not
// others, from a click that said nothing about doing part of it.
describe("a package-wide toggle across several places", () => {
  beforeEach(() => {
    stub.toggled = [];
    useEditorStore.setState({ scope: VG, draft: null, dirty: false, held: {} });
  });

  it("writes every place when none of them has unsaved typing", () => {
    const { body } = render();
    (body.onToggle as (enable: boolean) => void)(false);
    expect(stub.toggled.length).toBeGreaterThan(0);
  });

  it("writes none of them when one does", () => {
    useEditorStore.setState({
      held: {
        [HYPR.root]: {
          scope: HYPR,
          draft: { schema: 1, install: {} },
          base: "read-earlier",
        },
      },
    });
    const { body } = render();
    (body.onToggle as (enable: boolean) => void)(false);
    expect(stub.toggled).toEqual([]);
  });
});
