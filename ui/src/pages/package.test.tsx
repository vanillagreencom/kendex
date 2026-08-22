import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { updateRow } from "@/components/updates-test-rows";
import { UNSAVED_ELSEWHERE_TITLE } from "@/lib/copy-customize";
import type { PlaceStanding } from "@/lib/customized-places";
import { emptyDraft } from "@/lib/editor-draft";
import { PackagePage } from "./package";
import { freshWorld, HYPR, type PageWorld, VG } from "./package-test-world";

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

const world = vi.hoisted(() => ({ at: null as unknown as PageWorld }));

vi.mock("@/components/package/use-package-data", async (importOriginal) => {
  const mod =
    await importOriginal<
      typeof import("@/components/package/use-package-data")
    >();
  return {
    ...mod,
    usePackageData: () => ({
      meta: world.at.meta,
      files: [],
      versions: world.at.versions,
      load: () => {},
    }),
    usePackageDiff: () => null,
    useManifestBusy: () => false,
  };
});

vi.mock("@/stores/nav", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/nav")>();
  const { stubbed } = await import("./package-test-world");
  return {
    ...mod,
    useNavStore: stubbed(mod.useNavStore, () => ({
      packageRef: { kind: "skill", name: "gh", scope: world.at.scope },
      packageView: null,
      clearPackageView: () => {},
      back: () => {},
    })),
  };
});

vi.mock("@/stores/scan", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/scan")>();
  const { scanned, stubbed } = await import("./package-test-world");
  return {
    ...mod,
    useScanStore: stubbed(mod.useScanStore, () => ({ result: scanned() })),
  };
});

vi.mock("@/stores/editor", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/editor")>();
  const { stubbed } = await import("./package-test-world");
  return {
    ...mod,
    useEditorStore: stubbed(mod.useEditorStore, () => ({
      scope: world.at.editorScope,
      draft: null,
      saved: world.at.saved,
      held: world.at.held,
      saving: false,
      manifestsLoaded: true,
      manifestError: null,
      openScope: async () => {},
    })),
  };
});

vi.mock("@/stores/updates", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/updates")>();
  const { stubbed } = await import("./package-test-world");
  return {
    ...mod,
    useUpdatesStore: stubbed(mod.useUpdatesStore, () => ({
      rows: world.at.rows,
      loaded: true,
      checking: world.at.checking,
      busy: false,
      error: null,
    })),
  };
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
  world.at = freshWorld();
});

describe("what the package page is about", () => {
  it("takes its installation from the place it was opened at", () => {
    expect((render().body.primary as { path: string }).path).toBe(
      "/work/vg/gh",
    );
    world.at.scope = HYPR;
    expect((render().body.primary as { path: string }).path).toBe(
      "/work/hyprtrade/gh",
    );
  });

  it("speaks for the place it was opened at, whatever the chips have open", () => {
    // The editor points somewhere else: the package last edited before this
    // page opened, or the place a Customize chip was clicked. Either way the
    // title names the place the installation, the actions and the notice
    // below it are about, or the page says one thing and does another.
    expect((render().header.place as PlaceStanding).scope).toEqual(VG);
    world.at.editorScope = VG;
    world.at.scope = HYPR;
    expect((render().header.place as PlaceStanding).scope).toEqual(HYPR);
  });

  it("reads its edited-files notice off the place it was opened at", () => {
    world.at.rows = [
      updateRow("gh", "/work/vg", {
        updateAvailable: false,
        blockedByLocalEdit: true,
      }),
      updateRow("gh", "/work/hyprtrade", { updateAvailable: false }),
    ];
    expect((render().body.editedRow as { scope: unknown }).scope).toEqual(VG);
    world.at.scope = HYPR;
    expect(render().body.editedRow).toBe(null);
  });

  // Arriving here is what parks typing left at another place, so this is
  // the page that has to say where it went — above the tabs, since landing
  // on Overview must not hide it.
  it("names typing parked at another place, whatever tab is open", () => {
    expect(renderToStaticMarkup(<PackagePage />)).not.toContain(
      UNSAVED_ELSEWHERE_TITLE,
    );
    world.at.held = {
      "/work/hyprtrade": {
        scope: HYPR,
        draft: emptyDraft(),
        base: null,
      },
    };
    const html = renderToStaticMarkup(<PackagePage />);
    expect(html).toContain(UNSAVED_ELSEWHERE_TITLE);
    expect(html).toContain("/work/hyprtrade");
  });

  // The button applies the revision the last read named, so a read still on
  // its way means the version on screen is the one it is about to replace.
  it("does not offer an update while a check is still on its way", () => {
    world.at.rows = [
      updateRow("gh", "/work/vg", { updateAvailable: true, canDiscard: true }),
    ];
    expect(render().actions.updateAvailable).toBe(true);

    world.at.checking = true;
    expect(render().actions.updateAvailable).toBe(false);
  });

  it("does not offer an update for a place its edits are holding", () => {
    // The control: everything the Update button needs is in place.
    world.at.rows = [
      updateRow("gh", "/work/vg", { updateAvailable: true, canDiscard: true }),
    ];
    expect(render().actions.updateAvailable).toBe(true);
    // The edit is what holds it, and the engine would refuse the apply.
    world.at.rows = [
      updateRow("gh", "/work/vg", {
        updateAvailable: true,
        blockedByLocalEdit: true,
        canDiscard: true,
      }),
    ];
    expect(render().actions.updateAvailable).toBe(false);
  });
});
