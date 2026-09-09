// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import type { PackageView } from "@/bindings";
import { mount } from "@/test/dom";
import { AvailableAside } from "./available-aside";

const view = (bundles: string[]): PackageView =>
  ({
    preview: {
      kind: "skill",
      name: "gh",
      description: null,
      tags: [],
      readme: null,
      files: [],
      bundles,
      dependencies: { required: [], optional: [] },
      state: "available",
      collision: null,
    },
    safety: null,
  }) as never;

const named = (host: HTMLElement, text: string) => {
  const found = [...host.querySelectorAll("button")].find(
    (button) => button.textContent === text,
  );
  if (!found) throw new Error(`no button named ${text}`);
  return found;
};

// The facts column names two things a reader can go to: the marketplace the
// package comes from — under the name `lib/marketplace-display.ts` resolved,
// which the breadcrumb and the marketplace's own page also use — and each
// curated set that carries it.
describe("the names in an available package's facts column", () => {
  const mountAside = (bundles: string[]) => {
    const onOpenMarketplace = vi.fn();
    const onOpenBundle = vi.fn();
    const host = mount(
      <AvailableAside
        marketplace="kit"
        repo={null}
        view={view(bundles)}
        selectedFile={null}
        onSelectFile={() => {}}
        onOpenMarketplace={onOpenMarketplace}
        onOpenBundle={onOpenBundle}
      />,
    );
    return { host, onOpenMarketplace, onOpenBundle };
  };

  it("opens the marketplace it came from", async () => {
    const { host, onOpenMarketplace, onOpenBundle } = mountAside([]);
    await userEvent.click(named(host, "kit"));
    expect(onOpenMarketplace).toHaveBeenCalledTimes(1);
    expect(onOpenBundle).not.toHaveBeenCalled();
  });

  it("opens each curated set that carries it, by name", async () => {
    const { host, onOpenBundle, onOpenMarketplace } = mountAside([
      "starter",
      "review",
    ]);
    await userEvent.click(named(host, "review"));
    expect(onOpenBundle).toHaveBeenCalledWith("review");
    expect(onOpenMarketplace).not.toHaveBeenCalled();
  });
});
