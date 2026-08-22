import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ItemKind, Scope } from "@/bindings";
import { observedItem } from "@/lib/observed-test-item";
import { CustomizedIndex } from "./customized-index";

const VG: Scope = { scope: "project", root: "/work/vg" };

// The button is mocked to hand back what it was given: a click handler
// cannot be invoked through static markup, and what this pins is the
// argument the page passes, not React's dispatch.
const clicks: (() => void)[] = [];
vi.mock("@/components/ui/button", () => ({
  Button: ({ onClick }: { onClick?: () => void }) => {
    if (onClick) clicks.push(onClick);
    return null;
  },
}));

const goToPackage = vi.hoisted(() => vi.fn());
vi.mock("@/stores/nav", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/nav")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = { ...mod.useNavStore.getState(), goToPackage };
    return selector ? selector(state) : state;
  };
  return { ...mod, useNavStore: Object.assign(hook, mod.useNavStore) };
});

vi.mock("@/stores/scan", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/scan")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.useScanStore.getState(),
      result: { items: [observedItem({ name: "gh", scope: VG })] },
    };
    return selector ? selector(state) : state;
  };
  return { ...mod, useScanStore: Object.assign(hook, mod.useScanStore) };
});

beforeEach(() => {
  clicks.length = 0;
  goToPackage.mockClear();
});

// Every row here is an overlay written on the Customize tab, so opening one
// on the overview lands away from the thing the row is about.
describe("the Customize index's Open", () => {
  it("opens the tab that wrote what the row lists", () => {
    renderToStaticMarkup(
      <CustomizedIndex
        items={[
          {
            kind: "skill" as ItemKind,
            name: "gh",
            customization: {
              launch: null,
              additional: null,
              instructions: "use the CLI",
              skills: null,
              frontmatter: [],
            },
          },
        ]}
        scope={VG}
        onRemove={() => {}}
      />,
    );
    expect(clicks).toHaveLength(1);
    clicks[0]();
    expect(goToPackage).toHaveBeenCalledWith(
      { kind: "skill", name: "gh", scope: VG },
      { mode: "customize" },
    );
  });
});
