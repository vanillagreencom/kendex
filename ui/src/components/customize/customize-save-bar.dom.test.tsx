// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from "vitest";
import type { ScopeSettings } from "@/bindings";
import { CustomizeSaveBar } from "@/components/customize/customize-save-bar";
import { SAVE_CONFIRM_SECRET_NOTE } from "@/lib/copy-customize";
import { useEditorStore } from "@/stores/editor";
import { mount } from "@/test/dom";
import { placeRead } from "@/test/settings-read";

const settings = {
  ...placeRead,
  skills: [],
} as unknown as ScopeSettings;

const typed = {
  skill: "linear",
  key: "LINEAR_API_KEY",
  value: { kind: "set" as const, value: "lin_dummy" },
};
const erased = { ...typed, value: { kind: "set" as const, value: "" } };
const setting = {
  skill: "gh",
  key: "GH_MODE",
  value: { kind: "set" as const, value: "advise" },
};

describe("CustomizeSaveBar", () => {
  beforeEach(() => {
    useEditorStore.setState({
      dirty: true,
      confirming: true,
      saving: false,
      manifestDirty: false,
      manifestFile: "kendex.toml",
      settingsEdits: [],
      secretEdits: [],
      secretFile: null,
      settings,
    });
  });

  /// The dialog and the save have to agree about what the save carries.
  /// A field typed into and then erased is not an answer — core refuses an
  /// empty value — so naming the private file and its key over a save that
  /// writes neither would tell a person a credential is going somewhere it
  /// is not.
  it("names the private file when the save carries a credential", () => {
    // The dialog renders through a portal, so the page is what it lands
    // on rather than the host the bar mounted into.
    useEditorStore.setState({ secretEdits: [typed] });
    mount(<CustomizeSaveBar />);
    const carrying = document.body.textContent ?? "";
    expect(carrying).toContain(".env.local");
    expect(carrying).toContain("LINEAR_API_KEY");
    expect(carrying).toContain(SAVE_CONFIRM_SECRET_NOTE);
  });

  /// The other half of the same rule: erased, the save carries no secret
  /// half, so the dialog names neither the file nor the key.
  it("names no private file for a field typed into and erased", () => {
    useEditorStore.setState({
      secretEdits: [erased],
      settingsEdits: [setting],
    });
    mount(<CustomizeSaveBar />);
    const shown = document.body.textContent ?? "";
    expect(shown).not.toContain(".env.local");
    expect(shown).not.toContain("LINEAR_API_KEY");
    expect(shown).not.toContain(SAVE_CONFIRM_SECRET_NOTE);
    // The change that kept the bar up is still named.
    expect(shown).toContain("GH_MODE");
  });
});
