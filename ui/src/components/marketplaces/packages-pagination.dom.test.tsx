// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act, useState } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import { installSelectedLabel, SELECT_EVERY_ROW } from "@/lib/copy-install";
import { useBookmarksStore } from "@/stores/bookmarks";
import { useInstallFlow } from "@/stores/install-flow";
import {
  marketKey,
  subscription,
  useMarketplacesStore,
} from "@/stores/marketplaces";
import { dropCatalogCaches, readErrorKey } from "@/stores/marketplaces-shared";
import { usePreinstallSafety } from "@/stores/preinstall-safety";
import { mount, settle } from "@/test/dom";
import { packagesFixture as world } from "@/test/fixtures/packages";
import type { PackageEntry } from "./package-row";
import { PackagesTab } from "./packages-tab";
import { PackagesTable } from "./packages-table";

vi.mock("@/bindings", () => ({
  commands: {
    marketplacePackagePreview: vi.fn(),
    marketplacePackages: vi.fn(),
  },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const loadPackages = useMarketplacesStore.getState().loadPackages;

beforeEach(() => {
  vi.mocked(commands.marketplacePackages).mockReset();
  vi.mocked(commands.marketplacePackagePreview).mockReset();
  // Hold the first preview to inspect what can run after navigation. The
  // test ends by resolving it; no live backend or wall-clock wait is used.
  useMarketplacesStore.setState({
    rows: world.rows,
    packages: world.packages,
    readErrors: {},
    loadPackages,
  });
  useBookmarksStore.setState({
    saved: [],
    everRead: true,
    read: { status: "read" },
  });
  useInstallFlow.setState({ ask: null, outcome: null, running: false });
  dropCatalogCaches(() => {});
});

function Navigation() {
  const [here, setHere] = useState(true);
  return (
    <>
      <button type="button" onClick={() => setHere(!here)}>
        Change destination
      </button>
      {here ? <PackagesTab /> : <p>Settings</p>}
    </>
  );
}

describe("paged Packages demand", () => {
  it("keeps all 622 data rows, drops departed page demand and drains nothing after departure", async () => {
    let land: (value: unknown) => void = () => {};
    vi.mocked(commands.marketplacePackagePreview).mockReturnValueOnce(
      new Promise((resolve) => {
        land = resolve;
      }) as never,
    );
    const host = mount(<Navigation />);
    expect(
      Object.values(useMarketplacesStore.getState().packages).flat(),
    ).toHaveLength(622);
    expect(host.querySelectorAll("tbody tr")).toHaveLength(20);
    expect(host.textContent).toContain("1–20 of 622 packages");
    const firstName = vi.mocked(commands.marketplacePackagePreview).mock
      .calls[0][2];
    await userEvent.click(
      [...host.querySelectorAll("button")].find(
        (b) => b.textContent === "Next page",
      ) as HTMLButtonElement,
    );
    expect(host.querySelectorAll("tbody tr")).toHaveLength(20);
    expect(host.textContent).toContain("21–40 of 622 packages");
    const visible = new Set(
      [...host.querySelectorAll("tbody tr")].map(
        (row) => row.children[1].querySelector("button")?.textContent,
      ),
    );
    vi.mocked(commands.marketplacePackagePreview).mockResolvedValue({
      status: "error",
      error: "fixture",
    });
    await act(async () => {
      land({ status: "error", error: "fixture" });
    });
    const calls = vi.mocked(commands.marketplacePackagePreview).mock.calls;
    expect(calls.length).toBe(21);
    expect(calls[0][2]).toBe(firstName);
    expect(calls.slice(1).every((call) => visible.has(call[2]))).toBe(true);
    await userEvent.click(
      [...host.querySelectorAll("button")].find(
        (b) => b.textContent === "Change destination",
      ) as HTMLButtonElement,
    );
    await settle();
    expect(commands.marketplacePackagePreview).toHaveBeenCalledTimes(21);
    expect(host.querySelectorAll("tbody tr")).toHaveLength(0);
    expect(
      Object.values(useMarketplacesStore.getState().packages).flat(),
    ).toHaveLength(622);
  });

  it("drops queued previews when the page departs while a read is still running", async () => {
    let land: (value: unknown) => void = () => {};
    vi.mocked(commands.marketplacePackagePreview).mockReturnValueOnce(
      new Promise((resolve) => {
        land = resolve;
      }) as never,
    );
    const host = mount(<Navigation />);
    await userEvent.click(
      [...host.querySelectorAll("button")].find(
        (b) => b.textContent === "Change destination",
      ) as HTMLButtonElement,
    );
    await act(async () => {
      land({ status: "error", error: "fixture" });
    });
    expect(commands.marketplacePackagePreview).toHaveBeenCalledTimes(1);
  });

  it("selects the whole result, not just the mounted page", async () => {
    vi.mocked(commands.marketplacePackagePreview).mockResolvedValue({
      status: "error",
      error: "fixture",
    });
    const host = mount(<PackagesTab />);
    await userEvent.click(
      host.querySelector(`[aria-label="${SELECT_EVERY_ROW}"]`) as HTMLElement,
    );
    await userEvent.click(
      [...host.querySelectorAll("button")].find(
        (b) => b.textContent === installSelectedLabel(561),
      ) as HTMLButtonElement,
    );
    const subject = useInstallFlow.getState().ask?.subjects[0];
    expect(subject?.count).toBe(561);
    expect(subject?.groups.flatMap((g) => g.items)).toHaveLength(561);
    await userEvent.click(
      [...host.querySelectorAll("button")].find(
        (b) => b.textContent === "Next page",
      ) as HTMLButtonElement,
    );
    expect(
      [...host.querySelectorAll('tbody [role="checkbox"]')].every(
        (b) => b.getAttribute("aria-checked") === "true",
      ),
    ).toBe(true);
  });

  it("filters offscreen rows and resets paging without discarding cached data", async () => {
    vi.mocked(commands.marketplacePackagePreview).mockResolvedValue({
      status: "error",
      error: "fixture",
    });
    const host = mount(<PackagesTab />);
    await userEvent.click(
      [...host.querySelectorAll("button")].find(
        (b) => b.textContent === "Next page",
      ) as HTMLButtonElement,
    );
    const input = host.querySelector(
      'input[placeholder="Search packages"]',
    ) as HTMLInputElement;
    await userEvent.type(input, "react-best-practices");
    expect(host.querySelectorAll("tbody tr")).toHaveLength(1);
    expect(host.textContent).toContain("react-best-practices");
    await userEvent.clear(input);
    expect(host.textContent).toContain("1–20 of 622 packages");
    expect(
      Object.values(useMarketplacesStore.getState().packages).flat(),
    ).toHaveLength(622);
  });

  it("coalesces partial arrivals and leaves failed catalogs for explicit retry", async () => {
    const lands: ((value: unknown) => void)[] = [];
    useMarketplacesStore.setState({ packages: {} });
    vi.mocked(commands.marketplacePackages).mockImplementation(
      () =>
        new Promise((resolve) => {
          lands.push(resolve as never);
        }),
    );
    vi.mocked(commands.marketplacePackagePreview).mockResolvedValue({
      status: "error",
      error: "fixture",
    });
    const host = mount(<PackagesTab />);
    expect(commands.marketplacePackages).toHaveBeenCalledTimes(4);
    for (let index = 0; index < 4; index += 1) {
      const row = world.rows[index];
      await act(async () => {
        lands[index](
          index === 0
            ? { status: "error", error: "cannot read" }
            : {
                status: "ok",
                data: world.packages[marketKey(row.scope, row.name)],
              },
        );
      });
      expect(commands.marketplacePackages).toHaveBeenCalledTimes(4);
    }
    const row = world.rows[0];
    const key = marketKey(row.scope, row.name);
    expect(
      useMarketplacesStore.getState().readErrors[readErrorKey(key, "packages")],
    ).toBe("cannot read");
    await userEvent.click(
      [...host.querySelectorAll("button")].find(
        (button) => button.textContent === TRY_AGAIN_LABEL,
      ) as HTMLButtonElement,
    );
    expect(commands.marketplacePackages).toHaveBeenLastCalledWith(
      subscription(row.scope, row.name),
    );
    await act(async () => {
      lands[4]({ status: "ok", data: world.packages[key] });
    });
    expect(commands.marketplacePackages).toHaveBeenCalledTimes(5);
    expect(
      Object.values(useMarketplacesStore.getState().packages).flat(),
    ).toHaveLength(622);
    expect(
      useMarketplacesStore.getState().readErrors[readErrorKey(key, "packages")],
    ).toBeUndefined();
    expect(host.querySelectorAll("tbody tr")).toHaveLength(20);
    expect(host.textContent).toContain("1–20 of 622 packages");
    expect(host.querySelector('[role="alert"]')).toBeNull();
  });
});

it("sorts the full result before paging and retains individual selections across pages", async () => {
  vi.mocked(commands.marketplacePackagePreview).mockResolvedValue({
    status: "error",
    error: "fixture",
  });
  const row = world.rows[0];
  const catalog = subscription(row.scope, row.name);
  const entries: PackageEntry[] = Array.from({ length: 45 }, (_, index) => ({
    catalog,
    recordsUnreadable: false,
    row: {
      ...Object.values(world.packages)[0][0],
      kind: "skill",
      state: "available",
      name: `package-${String(index).padStart(3, "0")}`,
    },
  }));
  const host = mount(<PackagesTable entries={entries} showMarketplace />);
  await userEvent.click(
    host.querySelector('[aria-label="Select package-000"]') as HTMLElement,
  );
  await userEvent.click(
    host.querySelector(
      '[aria-label="Sorted by Name ascending"]',
    ) as HTMLElement,
  );
  expect(host.querySelectorAll("tbody tr")).toHaveLength(20);
  expect(host.querySelector("tbody tr")?.textContent).toContain("package-044");
  await userEvent.click(
    [...host.querySelectorAll("button")].find(
      (b) => b.textContent === "Next page",
    ) as HTMLButtonElement,
  );
  await userEvent.click(
    [...host.querySelectorAll("button")].find(
      (b) => b.textContent === "Next page",
    ) as HTMLButtonElement,
  );
  expect(host.querySelectorAll("tbody tr")).toHaveLength(5);
  expect(
    host
      .querySelector('[aria-label="Select package-000"]')
      ?.getAttribute("aria-checked"),
  ).toBe("true");
  expect(
    [...host.querySelectorAll("button")].find(
      (b) => b.textContent === "Next page",
    )?.disabled,
  ).toBe(true);
  expect(usePreinstallSafety.getState().scores).toEqual({});
});
