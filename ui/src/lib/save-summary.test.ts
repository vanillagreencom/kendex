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
        pickedFile: null,
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
        pickedFile: null,
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
        pickedFile: null,
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
      pickedFile: null,
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

  /// The dialog says it lists every file the save writes, and a first
  /// credential save writes the ignore entry first. Leaving it out would
  /// make that claim false on the one save it matters most on.
  it("names the ignore entry a first save writes", () => {
    const missing = settings({
      secrets: {
        destination: {
          file: ".env.local",
          chosen: false,
          state: { state: "missing", ignore: "/.env.local" },
        },
        candidates: [],
        base: null,
      },
    });
    expect(
      saveGroups({
        manifestDirty: false,
        manifestFile: "kendex.toml",
        settingsEdits: [],
        secretEdits: [secret("LINEAR_API_KEY", "k")],
        pickedFile: null,
        settings: missing,
      }).map((group) => [group.file, group.labels]),
    ).toEqual([
      [".gitignore", ["/.env.local"]],
      [".env.local", ["LINEAR_API_KEY"]],
    ]);
    // The inverse: a save that stores nothing there takes the file on
    // for nobody, so no ignore entry is claimed.
    expect(
      saveGroups({
        manifestDirty: false,
        manifestFile: "kendex.toml",
        settingsEdits: [],
        secretEdits: [
          { skill: "linear", key: "LINEAR_API_KEY", value: { kind: "clear" } },
        ],
        pickedFile: null,
        settings: missing,
      }).map((group) => group.file),
    ).toEqual([".env.local"]);
  });

  /// Naming a private file the project does not already name is a write
  /// into the settings file, under the key both package loaders read. It
  /// is one line of the same group the public settings go in, because it
  /// lands in the same file.
  it("names a chosen private file as a settings write", () => {
    const groups = saveGroups({
      manifestDirty: false,
      manifestFile: "kendex.toml",
      settingsEdits: [setting("GH_MODE")],
      secretEdits: [],
      pickedFile: ".env.secrets",
      settings: settings({
        secrets: {
          destination: {
            file: ".env.secrets",
            chosen: false,
            state: { state: "ready" },
          },
          candidates: [],
          base: "p1",
        },
      }),
    });
    expect(groups.map((group) => [group.file, group.labels])).toEqual([
      ["kendex.settings.toml", ["GH_MODE", "KENDEX_ENV_FILE"]],
    ]);
  });

  /// A pick that changes nothing is not a change: the project already
  /// names that file, so the save writes no key and the summary claims
  /// none.
  it("claims no settings write for a file the project already names", () => {
    expect(
      saveGroups({
        manifestDirty: false,
        manifestFile: "kendex.toml",
        settingsEdits: [],
        secretEdits: [],
        pickedFile: ".env.secrets",
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
      }),
    ).toEqual([]);
  });
});
