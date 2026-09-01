// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it } from "vitest";
import type { VersionRow } from "@/bindings";
import { FOLLOW_SOURCE_LABEL, SWITCH_VERSION_LABEL } from "@/lib/copy";
import { UPDATES_ONE_AT_A_TIME_NOTE } from "@/lib/copy-updates";
import { useUpdatesStore } from "@/stores/updates";
import { mount } from "@/test/dom";
import { VersionMenu } from "./version-menu";

const versions: VersionRow[] = [
  {
    id: "a".repeat(40),
    label: "v1",
    date: "2025-12-01T00:00:00Z",
    summary: "the installed one",
    installed: true,
    newerThanInstalled: false,
  },
  {
    id: "b".repeat(40),
    label: "v2",
    date: "2026-01-01T00:00:00Z",
    summary: "the newest",
    installed: false,
    newerThanInstalled: true,
  },
];

const button = (label: string): HTMLButtonElement => {
  const found = [...document.querySelectorAll("button")].find(
    (one) => one.textContent === label,
  );
  if (!found) throw new Error(`no button "${label}"`);
  return found;
};

/** Open the picker and choose the version that is not installed, which is
 *  what puts Switch to this version on screen. */
const pickNewest = async () => {
  const trigger = [...document.querySelectorAll("button")].find((one) =>
    one.textContent?.includes("v1"),
  );
  if (!trigger) throw new Error("no version trigger");
  act(() => trigger.focus());
  await userEvent.keyboard("{Enter}");
  const item = [...document.querySelectorAll('[role="menuitem"]')].find((el) =>
    el.textContent?.includes("the newest"),
  );
  if (!(item instanceof HTMLElement)) throw new Error("no v2 item");
  await userEvent.click(item);
};

beforeEach(() => {
  useUpdatesStore.setState({ checking: false, busy: false });
});

// Both of these apply a scope, which commits through the updates store. A
// check builds its report once, so a commit landing while it is out would
// be missing from it and the landing would put the rows back.
describe("VersionMenu's two writes under a running check", () => {
  it("holds each one, and each says which work it waits on", async () => {
    mount(
      <VersionMenu
        versions={versions}
        held
        busy={false}
        onSwitch={() => {}}
        onCompare={() => {}}
        onFollow={() => {}}
      />,
    );
    await pickNewest();

    expect(button(SWITCH_VERSION_LABEL).disabled).toBe(false);
    expect(button(FOLLOW_SOURCE_LABEL).disabled).toBe(false);

    await act(async () => {
      useUpdatesStore.setState({ checking: true });
    });

    for (const label of [SWITCH_VERSION_LABEL, FOLLOW_SOURCE_LABEL]) {
      expect(button(label).disabled).toBe(true);
      expect(button(label).title).toBe(UPDATES_ONE_AT_A_TIME_NOTE);
    }
    useUpdatesStore.setState({ checking: false });
  });
});
