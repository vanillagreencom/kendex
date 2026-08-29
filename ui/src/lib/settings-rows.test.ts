import { describe, expect, it } from "vitest";
import type { ScopeSettings, SettingsEdit, SettingsRow } from "@/bindings";
import {
  differsFromDefault,
  editIn,
  effectiveValue,
  rowsOf,
  settingsDraft,
  settingsValues,
  skillIn,
  withEdit,
} from "./settings-rows";

const row = (over: Partial<SettingsRow> = {}): SettingsRow => ({
  key: "GH_MODE",
  explainer: ["what it does"],
  default: "enforce",
  current: { state: "value", value: "enforce", line: 3 },
  ...over,
});

const set = (skill: string, key: string, value: string): SettingsEdit => ({
  skill,
  key,
  value: { kind: "set", value },
});

const place = (skills: ScopeSettings["skills"]): ScopeSettings => ({
  applies: true,
  skills,
  base: "b1",
});

describe("effectiveValue", () => {
  /// The draft is what the save will write, so it outranks the file for
  /// everything the row says about itself.
  it("prefers the draft over what the file holds", () => {
    expect(effectiveValue(row(), set("gh", "GH_MODE", "advise"))).toBe(
      "advise",
    );
    expect(
      effectiveValue(row(), {
        skill: "gh",
        key: "GH_MODE",
        value: { kind: "reset" },
      }),
    ).toBe("enforce");
  });

  /// Only a `value` current is an answer about the value: the other two
  /// say what is in the way instead, and reading either as a value would
  /// have the row show something the file does not hold.
  it("has no value for a key the file cannot be read on", () => {
    expect(effectiveValue(row({ current: { state: "absent" } }))).toBeNull();
    expect(
      effectiveValue(
        row({ current: { state: "ambiguous", problem: "twice", lines: [3] } }),
      ),
    ).toBeNull();
  });
});

describe("differsFromDefault", () => {
  it("compares only a value the file answers with", () => {
    expect(differsFromDefault(row())).toBe(false);
    expect(
      differsFromDefault(
        row({ current: { state: "value", value: "advise", line: 3 } }),
      ),
    ).toBe(true);
    expect(differsFromDefault(row({ current: { state: "absent" } }))).toBe(
      false,
    );
  });

  /// An empty value is a value: a key set to nothing where the default is
  /// something is off the default, and reading empty as unset would hide
  /// the one edit hardest to see in the file.
  it("counts an empty value against a default that is not", () => {
    expect(differsFromDefault(row(), set("gh", "GH_MODE", ""))).toBe(true);
  });
});

describe("withEdit", () => {
  /// Two answers for one key stop the whole save in core, so a second
  /// keystroke on a row replaces its answer rather than adding one.
  it("replaces the earlier answer for the same key of the same skill", () => {
    const edits = withEdit(
      [set("gh", "GH_MODE", "advise")],
      set("gh", "GH_MODE", "off"),
    );
    expect(edits).toEqual([set("gh", "GH_MODE", "off")]);
  });

  it("keeps one answer per skill for a key two of them declare", () => {
    const edits = withEdit(
      [set("gh", "GH_MODE", "advise")],
      set("review-gate", "GH_MODE", "advise"),
    );
    expect(edits).toHaveLength(2);
    expect(editIn(edits, "review-gate", "GH_MODE")).toEqual(
      set("review-gate", "GH_MODE", "advise"),
    );
  });
});

describe("rowsOf", () => {
  /// `invalid` says nothing about the settings file — seeding is lenient
  /// and may have written those keys anyway — so it yields no rows and
  /// the page renders the state rather than an empty list.
  it("yields rows only for the state that has them", () => {
    expect(rowsOf({ state: "rows", rows: [row()] })).toHaveLength(1);
    expect(rowsOf({ state: "no-template" })).toEqual([]);
    expect(rowsOf({ state: "unreadable", reason: "gone" })).toEqual([]);
    expect(
      rowsOf({
        state: "invalid",
        findings: [{ line: 1, problem: "p", fix: "f" }],
      }),
    ).toEqual([]);
  });
});

describe("skillIn", () => {
  it("has no entry where the place has no settings file", () => {
    const global: ScopeSettings = { applies: false, skills: [], base: null };
    expect(skillIn(global, "gh")).toBeNull();
    expect(skillIn(null, "gh")).toBeNull();
  });

  it("finds the named skill's entry", () => {
    const read = place([{ skill: "gh", template: { state: "no-template" } }]);
    expect(skillIn(read, "gh")?.template.state).toBe("no-template");
    expect(skillIn(read, "zed")).toBeNull();
  });
});

describe("settingsValues", () => {
  /// A place absent from the reads is absent from the map: the fact is
  /// unknown until its read lands, and an empty set would say the place
  /// was read and holds nothing.
  it("keys only the places that were read", () => {
    const values = settingsValues({
      "/work/vg": place([
        {
          skill: "gh",
          template: {
            state: "rows",
            rows: [
              row({ current: { state: "value", value: "advise", line: 3 } }),
            ],
          },
        },
        { skill: "zed", template: { state: "rows", rows: [row()] } },
      ]),
    });
    expect(values.get("/work/vg")).toEqual(new Set(["gh"]));
    expect(values.has("/work/hyprtrade")).toBe(false);
  });

  it("gives a place that holds nothing an empty answer, not none", () => {
    const values = settingsValues({
      global: { applies: false, skills: [], base: null },
    });
    expect(values.get("global")).toEqual(new Set());
  });
});

describe("settingsDraft", () => {
  /// A save with no settings edits carries no settings half: the base of
  /// a file nothing wants to write is not a claim worth making.
  it("is absent with no edits and carries the read base with them", () => {
    const read = place([]);
    expect(settingsDraft([], read)).toBeNull();
    expect(settingsDraft([set("gh", "GH_MODE", "off")], read)).toEqual({
      edits: [set("gh", "GH_MODE", "off")],
      base: "b1",
    });
  });

  /// A place with no settings file yet has no base, and null is what says
  /// so — the save creates the file rather than being refused over it.
  it("carries a null base where the read had none", () => {
    expect(settingsDraft([set("gh", "GH_MODE", "off")], null)?.base).toBeNull();
  });
});
