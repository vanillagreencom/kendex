// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from "vitest";
import type { Scope, ScopeSettings, SettingsEdit } from "@/bindings";
import { emptyDraft } from "@/lib/editor-draft";
import { READ_PENDING } from "@/lib/read-state";
import { scopeKey } from "@/lib/scope";
import { useEditorStore } from "@/stores/editor";
import { useUpdatesStore } from "@/stores/updates";
import { mount } from "@/test/dom";
import { useCustomizedHere } from "./customized-here";

const VG: Scope = { scope: "project", root: "/work/vg" };

/** gh declaring one key, standing at `value` in this place's file. */
const place = (value: string): ScopeSettings => ({
  applies: true,
  base: "b1",
  skills: [
    {
      skill: "gh",
      template: {
        state: "rows",
        rows: [
          {
            key: "GH_MODE",
            explainer: ["what it does"],
            default: "enforce",
            current: { state: "value", value, line: 3 },
          },
        ],
      },
    },
  ],
});

const setEdit = (value: SettingsEdit["value"]): SettingsEdit => ({
  skill: "gh",
  key: "GH_MODE",
  value,
});

/** What the index lists, read through the hook the page calls. */
function Index() {
  return (
    <span>
      {useCustomizedHere(null, VG)
        .map((r) => r.name)
        .join(",")}
    </span>
  );
}

const listed = (read: ScopeSettings, edits: SettingsEdit[]): string => {
  useEditorStore.setState({
    saved: { [scopeKey(VG)]: emptyDraft() },
    savedSettings: { [scopeKey(VG)]: read },
    settingsEdits: edits,
  });
  return mount(<Index />).textContent ?? "";
};

beforeEach(() => {
  useUpdatesStore.setState({ rows: [], read: READ_PENDING });
});

// The page skips its reload while anything is unsaved, so the index goes
// on answering from the last save unless the edits in hand count. The
// manifest half of the same page already reads its draft, and a draft
// counting on one half of a page and not the other is the mismatch.
describe("useCustomizedHere", () => {
  it("lists a package an unsaved settings value has just made theirs", () => {
    expect(listed(place("enforce"), [])).toBe("");
    expect(
      listed(place("enforce"), [setEdit({ kind: "set", value: "advise" })]),
    ).toBe("gh");
  });

  it("drops one an unsaved reset has just handed back", () => {
    expect(listed(place("advise"), [])).toBe("gh");
    expect(listed(place("advise"), [setEdit({ kind: "reset" })])).toBe("");
  });
});
