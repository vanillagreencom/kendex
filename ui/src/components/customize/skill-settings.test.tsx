// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import type React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { ScopeSettings, SettingsRow, SkillTemplate } from "@/bindings";
import {
  SETTINGS_DEFAULT_EMPTY,
  SETTINGS_HELP,
  SETTINGS_RESET,
  SETTINGS_TEMPLATE_INVALID,
  SETTINGS_TEMPLATE_INVALID_NOTE,
  SETTINGS_TEMPLATE_UNREADABLE,
} from "@/lib/copy-customize";
import { mount } from "@/test/dom";
import { SkillSettings } from "./skill-settings";

const row = (over: Partial<SettingsRow> = {}): SettingsRow => ({
  key: "GH_MODE",
  explainer: ["How the gate answers.", "One of enforce or advise."],
  default: "enforce",
  current: { state: "value", value: "enforce", line: 3 },
  ...over,
});

const place = (template: SkillTemplate): ScopeSettings => ({
  applies: true,
  skills: [{ skill: "gh", template }],
  base: "s1",
});

// A static render escapes the apostrophes the copy is written with, so
// every assertion here reads the markup with them put back.
const markup = (element: React.ReactElement): string =>
  renderToStaticMarkup(element).replaceAll("&#x27;", "'");

const render = (settings: ScopeSettings | null) =>
  markup(
    <SkillSettings
      skill="gh"
      settings={settings}
      edits={[]}
      onEdit={() => {}}
    />,
  );

describe("SkillSettings", () => {
  it("lists each declared key with its explainer and the default as the placeholder", () => {
    const html = render(place({ state: "rows", rows: [row()] }));
    expect(html).toContain("GH_MODE");
    expect(html).toContain("How the gate answers. One of enforce or advise.");
    expect(html).toContain('placeholder="enforce"');
    expect(html).toContain('value="enforce"');
    expect(html).toContain(SETTINGS_HELP);
  });

  /// The section says what a save will do to which file, and that a value
  /// set outside it wins — the two things that decide whether editing
  /// here has any effect at all.
  it("names the file it writes and what outranks it", () => {
    const html = render(place({ state: "rows", rows: [row()] }));
    expect(html).toContain("kendex.settings.toml in the project root");
    expect(html).toContain(".env.local");
  });

  /// Stated as a fact about the file. A value can be off the default
  /// because it was seeded, imported or hand-written, and nothing here
  /// knows who put it there.
  it("says a value differing from the default differs, never that anyone changed it", () => {
    const html = render(
      place({
        state: "rows",
        rows: [row({ current: { state: "value", value: "advise", line: 3 } })],
      }),
    );
    expect(html).toContain("Differs from the package default: enforce");
    expect(html).toContain(SETTINGS_RESET);
    expect(html).not.toMatch(/you changed|your change/i);
  });

  it("offers no reset for a key already holding the package default", () => {
    const html = render(place({ state: "rows", rows: [row()] }));
    expect(html).not.toContain(SETTINGS_RESET);
  });

  /// A key whose default is the empty string gets no placeholder from
  /// the default-as-placeholder rule, and a blank box states neither
  /// what the default is nor that empty is a real answer.
  it("states an empty package default rather than showing a blank box", () => {
    const container = mount(
      <SkillSettings
        skill="gh"
        settings={place({
          state: "rows",
          rows: [row({ default: "", current: { state: "absent" } })],
        })}
        edits={[]}
        onEdit={() => {}}
      />,
    );
    expect(container.querySelector("input")?.placeholder).toBe(
      SETTINGS_DEFAULT_EMPTY,
    );
  });

  /// Core refuses an edit on a key the file answers for in a shape no
  /// script reads, so the row offers no control and names the lines the
  /// person has to settle it on.
  it("renders an unreadable key read-only with the lines to settle it", () => {
    // Mounted, not rendered to a string: a static render accepts markup
    // React refuses at runtime, and this row nests a status line beside a
    // description that is itself a paragraph.
    const complained = vi.spyOn(console, "error").mockImplementation(() => {});
    const container = mount(
      <SkillSettings
        skill="gh"
        settings={place({
          state: "rows",
          rows: [
            row({
              current: {
                state: "ambiguous",
                problem: "it is assigned more than once",
                lines: [3, 9],
              },
            }),
          ],
        })}
        edits={[]}
        onEdit={() => {}}
      />,
    );
    expect(container.textContent).toContain(
      "it is assigned more than once: lines 3, 9",
    );
    expect(container.querySelector("input")).toBeNull();
    expect(complained).not.toHaveBeenCalled();
    complained.mockRestore();
  });

  /// Seeding is lenient, so a template the strict reader refuses may well
  /// have seeded its keys into the file. The section says the template is
  /// the problem — never that nothing is set.
  it("renders an invalid template as its findings, not as an empty section", () => {
    const html = render(
      place({
        state: "invalid",
        findings: [{ line: 4, problem: "no comment block", fix: "add one" }],
      }),
    );
    expect(html).toContain(SETTINGS_TEMPLATE_INVALID);
    expect(html).toContain(SETTINGS_TEMPLATE_INVALID_NOTE);
    expect(html).toContain("Line 4: no comment block — add one");
    expect(html).not.toMatch(/nothing is set|no settings/i);
  });

  it("says a template out of reach is out of reach", () => {
    const html = render(
      place({ state: "unreadable", reason: "its source has not arrived" }),
    );
    expect(html).toContain(SETTINGS_TEMPLATE_UNREADABLE);
    expect(html).toContain("its source has not arrived");
  });

  /// Global has no settings file — skills seed on a project install
  /// alone — and a skill that declares nothing has nothing to show.
  it("shows no section for global, a template-less skill, or an unread place", () => {
    expect(render({ applies: false, skills: [], base: null })).toBe("");
    expect(render(place({ state: "no-template" }))).toBe("");
    expect(render(place({ state: "rows", rows: [] }))).toBe("");
    expect(render(null)).toBe("");
  });

  /// The draft is what the save will write, so the row shows it in place
  /// of what the file currently holds.
  it("shows the unsaved answer over the one in the file", () => {
    const html = markup(
      <SkillSettings
        skill="gh"
        settings={place({ state: "rows", rows: [row()] })}
        edits={[
          {
            skill: "gh",
            key: "GH_MODE",
            value: { kind: "set", value: "advise" },
          },
        ]}
        onEdit={() => {}}
      />,
    );
    expect(html).toContain('value="advise"');
    expect(html).toContain("Differs from the package default: enforce");
  });

  /// Every edit names the skill whose template declares the key: core
  /// checks the edit against that declaration and refuses one written
  /// under somebody else's name.
  it("hands up a typed value bound to the skill that declares the key", async () => {
    const onEdit = vi.fn();
    const container = mount(
      <SkillSettings
        skill="gh"
        settings={place({ state: "rows", rows: [row()] })}
        edits={[]}
        onEdit={onEdit}
      />,
    );
    const input = container.querySelector("input");
    if (!input) throw new Error("the row rendered no input");
    await userEvent.clear(input);
    expect(onEdit).toHaveBeenLastCalledWith({
      skill: "gh",
      key: "GH_MODE",
      value: { kind: "set", value: "" },
    });
  });

  /// Reset asks core for the skill's own template default rather than
  /// sending the value the row happens to be showing: the template is
  /// the one place that default is written down.
  it("resets a row to the package default as a reset, not as a value", async () => {
    const onEdit = vi.fn();
    const container = mount(
      <SkillSettings
        skill="gh"
        settings={place({
          state: "rows",
          rows: [
            row({ current: { state: "value", value: "advise", line: 3 } }),
          ],
        })}
        edits={[]}
        onEdit={onEdit}
      />,
    );
    const reset = [...container.querySelectorAll("button")].find(
      (button) => button.textContent === SETTINGS_RESET,
    );
    if (!reset) throw new Error("the row offered no reset");
    await userEvent.click(reset);
    expect(onEdit).toHaveBeenCalledWith({
      skill: "gh",
      key: "GH_MODE",
      value: { kind: "reset" },
    });
  });
});
