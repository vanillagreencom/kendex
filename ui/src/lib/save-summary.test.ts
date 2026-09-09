import { describe, expect, it } from "vitest";
import type { ScopeSettings, SecretEdit, SettingsEdit } from "@/bindings";
import { placeRead } from "@/test/settings-read";
import { saveGroups } from "./save-summary";

const settings = (over: Partial<ScopeSettings> = {}): ScopeSettings => ({
  applies: true,
  ...placeRead,
  skills: [],
  base: "s1",
  ...over,
});

const setting = (key: string): SettingsEdit => ({
  skill: "gh",
  key,
  value: { kind: "set", value: "advise" },
});

const secret = (key: string, value: string): SecretEdit => ({
  skill: "linear",
  key,
  value: { kind: "set", value },
});

describe("saveGroups", () => {
  /// Three files, three groups, each named by the read it came from — the
  /// manifest names its own file, because a source catalog keeps its
  /// install state in a sibling of the definition it publishes.
  it("groups every change by the file it lands in", () => {
    expect(
      saveGroups({
        manifestDirty: true,
        manifestFile: "kendex-local.toml",
        settingsEdits: [setting("GH_MODE")],
        secretEdits: [secret("LINEAR_API_KEY", "k")],
        settings: settings(),
      }).map((group) => [group.file, group.labels]),
    ).toEqual([
      ["kendex-local.toml", ["Your customizations"]],
      ["kendex.settings.toml", ["GH_MODE"]],
      [".env.local", ["LINEAR_API_KEY"]],
    ]);
  });

  /// Only what changed. A save of one credential names one file, so a
  /// person confirming it is not told about two they did not touch.
  it("shows only the groups that changed", () => {
    expect(
      saveGroups({
        manifestDirty: false,
        manifestFile: "kendex.toml",
        settingsEdits: [],
        secretEdits: [secret("LINEAR_API_KEY", "k")],
        settings: settings(),
      }).map((group) => group.file),
    ).toEqual([".env.local"]);
  });

  /// The dialog exists so a person can check where a credential is going.
  /// Printing it on the way would be the opposite of that.
  it("names keys and never values", () => {
    const shown = JSON.stringify(
      saveGroups({
        manifestDirty: true,
        manifestFile: "kendex.toml",
        settingsEdits: [setting("GH_MODE")],
        secretEdits: [secret("LINEAR_API_KEY", "sk-live-secret")],
        settings: settings(),
      }),
    );
    expect(shown).not.toContain("sk-live-secret");
    expect(shown).toContain("LINEAR_API_KEY");
  });

  /// The private file is whichever one the destination resolved, so a
  /// project that named its own is confirmed against that name.
  it("names the private file the destination resolved", () => {
    const groups = saveGroups({
      manifestDirty: false,
      manifestFile: "kendex.toml",
      settingsEdits: [],
      secretEdits: [secret("LINEAR_API_KEY", "k")],
      settings: settings({
        secrets: {
          destination: {
            file: ".env.secrets",
            chosen: true,
            state: { state: "ready" },
          },
          candidates: [],
          base: "p1",
        },
      }),
    });
    expect(groups.map((group) => group.file)).toEqual([".env.secrets"]);
  });
});
