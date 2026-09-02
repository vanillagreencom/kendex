// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { PackageView } from "@/bindings";
import { commands } from "@/bindings";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { subscription } from "@/stores/marketplaces-shared";
import { useNavStore } from "@/stores/nav";
import { mount, settle } from "@/test/dom";
import { AvailablePackagePage } from "./available-package";

vi.mock("@/bindings", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/bindings")>();
  return {
    ...mod,
    commands: {
      ...mod.commands,
      marketplacePackagePreview: vi.fn(),
      installTargets: vi.fn(),
    },
  };
});

const catalog = subscription({ scope: "global" }, "kendex");

const view: PackageView = {
  preview: {
    kind: "skill",
    name: "dev",
    description: null,
    tags: [],
    readme: null,
    files: [],
    bundles: [],
    dependencies: {
      required: [],
      optional: [{ name: "linear", shown: "linear", state: "available" }],
    },
    collision: null,
  },
  safety: {
    kind: "skill",
    name: "dev",
    findings: [],
    safety: { score: 100, deductions: [] },
    quality: null,
    skipped: [],
    notes: [],
    contentHash: "abc",
    ruleset: 1,
    fromCache: false,
  },
};

const install = vi.fn().mockResolvedValue(true);

beforeEach(() => {
  install.mockClear();
  vi.mocked(commands.marketplacePackagePreview).mockResolvedValue({
    status: "ok",
    data: view,
  });
  vi.mocked(commands.installTargets).mockResolvedValue({
    status: "ok",
    data: [{ harness: "claude", detected: true, sharesTheUniversalTree: true }],
  });
  useMarketplacesStore.setState({ busy: false, install });
  useNavStore.setState({
    availableRef: { catalog, kind: "skill", name: "dev" },
  });
});

const open = async () => {
  mount(<AvailablePackagePage />);
  await settle();
};

/** Exactly this label: "Install to" and "Install for" are the pickers
 *  beside the button, and a loose match presses one of those instead. */
const click = async (label: string) => {
  const found = [...document.querySelectorAll("button")].find(
    (one) => one.textContent?.trim() === label,
  );
  if (!found) throw new Error(`no button "${label}"`);
  await userEvent.click(found);
};

/** The page is where a person ticks an optional extra and presses Install,
 *  so what the picker settles has to reach the install unchanged. */
describe("installing from the available-package page", () => {
  it("carries the ticked optional extra into the install", async () => {
    await open();
    // Open the picker: a base-ui trigger does not open on a click under
    // jsdom, so it is focused and Enter is pressed.
    const trigger = [...document.querySelectorAll("button")].find((one) =>
      one.textContent?.includes("Install for"),
    );
    if (!trigger) throw new Error("no picker trigger");
    act(() => trigger.focus());
    await userEvent.keyboard("{Enter}");
    const box = [...document.querySelectorAll("label")].find((one) =>
      one.textContent?.includes("linear"),
    );
    if (!box) throw new Error("no linear row");
    await userEvent.click(box);
    await userEvent.keyboard("{Escape}");
    await click("Install");

    expect(install).toHaveBeenCalledTimes(1);
    expect(install.mock.calls[0][0].delivery.optional).toEqual(["linear"]);
  });

  it("takes no extra where none was ticked", async () => {
    await open();
    await click("Install");

    expect(install.mock.calls[0][0].delivery.optional).toEqual([]);
  });
});
