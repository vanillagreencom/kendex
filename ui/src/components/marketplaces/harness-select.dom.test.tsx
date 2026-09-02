// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { PackageDependencies } from "@/bindings";
import { commands } from "@/bindings";
import { mount, settle } from "@/test/dom";
import { type Choice, HarnessSelect } from "./harness-select";

vi.mock("@/bindings", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/bindings")>();
  return {
    ...mod,
    commands: { ...mod.commands, installTargets: vi.fn() },
  };
});

const deps: PackageDependencies = {
  required: [
    { name: "code-quality", shown: "code-quality", state: "available" },
  ],
  optional: [{ name: "linear", shown: "linear", state: "available" }],
};

const untouched: Choice = { harnesses: null, method: null, optional: [] };

/** Open the picker: a base-ui trigger does not open on a click under
 *  jsdom, so it is focused and Enter is pressed. */
const openPicker = async () => {
  const trigger = [...document.querySelectorAll("button")].find((one) =>
    one.textContent?.includes("Install for"),
  );
  if (!trigger) throw new Error("no picker trigger");
  act(() => trigger.focus());
  await userEvent.keyboard("{Enter}");
};

const render = async (onChange: (choice: Choice) => void) => {
  mount(
    <HarnessSelect
      scope={{ scope: "global" }}
      kinds={["skill"]}
      dependencies={deps}
      value={untouched}
      onChange={onChange}
    />,
  );
  await settle();
  await openPicker();
};

beforeEach(() => {
  vi.mocked(commands.installTargets).mockResolvedValue({
    status: "ok",
    data: [{ harness: "claude", detected: true, sharesTheUniversalTree: true }],
  });
});

/** The picker is where an install's optional extras are chosen, so what it
 *  shows and what a tick produces are the contract the install reads. */
describe("the install picker's dependencies", () => {
  it("names what comes with the package and what it offers", async () => {
    await render(() => {});
    expect(document.body.textContent).toContain("code-quality");
    expect(document.body.textContent).toContain("linear");
  });

  it("hands the ticked extra back by name", async () => {
    const onChange = vi.fn();
    await render(onChange);
    const box = [...document.querySelectorAll("label")].find((one) =>
      one.textContent?.includes("linear"),
    );
    if (!box) throw new Error("no linear row");
    await userEvent.click(box);

    expect(onChange).toHaveBeenCalledWith({
      ...untouched,
      optional: ["linear"],
    });
  });

  it("shows nothing about dependencies for a package that declares none", async () => {
    mount(
      <HarnessSelect
        scope={{ scope: "global" }}
        kinds={["skill"]}
        dependencies={{ required: [], optional: [] }}
        value={untouched}
        onChange={() => {}}
      />,
    );
    await settle();
    await openPicker();

    expect(document.body.textContent).not.toContain("Installed only if you");
  });
});
