// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import type React from "react";
import { act } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type {
  ScopeSettings,
  SettingsEdit,
  SettingsRow,
  SkillTemplate,
} from "@/bindings";
import {
  CONTESTED_KEYS,
  SECRETS_NEED_A_PROJECT,
  SECRETS_SECTION,
  SETTINGS_DEFAULT_EMPTY,
  SETTINGS_HELP,
  SETTINGS_RESET,
  SETTINGS_TEMPLATE_INVALID,
  SETTINGS_TEMPLATE_INVALID_NOTE,
  SETTINGS_TEMPLATE_UNREADABLE,
  secretsHelp,
  secretsHelpRefused,
  settingDiffers,
} from "@/lib/copy-customize";
import { mount } from "@/test/dom";
import { SkillSettings } from "./skill-settings";

const row = (over: Partial<SettingsRow> = {}): SettingsRow => ({
  key: "GH_MODE",
  explainer: ["How the gate answers.", "One of enforce or advise."],
  default: "enforce",
  values: [],
  current: { state: "value", value: "enforce", line: 3 },
  ...over,
});

const place = (template: SkillTemplate): ScopeSettings => ({
  applies: true,
  skills: [{ skill: "gh", template }],
  file: "kendex.settings.toml",
  base: "s1",
  secrets: {
    destination: {
      file: ".env.local",
      chosen: false,
      state: { state: "ready" },
    },
    candidates: [],
    base: "p1",
  },
  contested: [],
});

/** The public half of a template, with no credentials declared — what
 *  every case below but the contested one is about. */
const publicRows = (rows: SettingsRow[]): SkillTemplate => ({
  state: "rows",
  rows,
  secrets: [],
});

// A static render escapes the apostrophes the copy is written with, so
// every assertion here reads the markup with them put back.
const markup = (element: React.ReactElement): string =>
  renderToStaticMarkup(element).replaceAll("&#x27;", "'");

/** The section on screen, for a case that reads the DOM or clicks. */
const mounted = (
  settings: ScopeSettings | null,
  onEdit: (edit: SettingsEdit) => void = () => {},
) =>
  mount(
    <SkillSettings
      skill="gh"
      settings={settings}
      edits={[]}
      secretEdits={[]}
      pickedFile={null}
      onEdit={onEdit}
      onSecretEdit={() => {}}
      onSecretEdits={() => {}}
      onPickFile={() => {}}
    />,
  );

/** Open this picker and return the options it offers. A base-ui trigger
 *  does not open on a click under jsdom, and every popup is portaled to
 *  the document, so what a case left open is still there: only the options
 *  this open added come back. */
const opened = async (trigger: HTMLElement): Promise<HTMLElement[]> => {
  const already = new Set(document.querySelectorAll('[role="option"]'));
  act(() => trigger.focus());
  await userEvent.keyboard("{Enter}");
  return [...document.querySelectorAll('[role="option"]')].filter(
    (one): one is HTMLElement =>
      one instanceof HTMLElement && !already.has(one),
  );
};

const render = (settings: ScopeSettings | null) =>
  markup(
    <SkillSettings
      skill="gh"
      settings={settings}
      edits={[]}
      secretEdits={[]}
      pickedFile={null}
      onEdit={() => {}}
      onSecretEdit={() => {}}
      onSecretEdits={() => {}}
      onPickFile={() => {}}
    />,
  );

describe("SkillSettings", () => {
  it("lists each declared key with its explainer and the default as the placeholder", () => {
    const html = render(place(publicRows([row()])));
    expect(html).toContain("GH_MODE");
    expect(html).toContain("How the gate answers. One of enforce or advise.");
    expect(html).toContain('placeholder="enforce"');
    expect(html).toContain('value="enforce"');
    expect(html).toContain(SETTINGS_HELP);
  });

  /// Stated as a fact about the file. A value can be off the default
  /// because it was seeded, imported or hand-written, and nothing here
  /// knows who put it there.
  it("says a value differing from the default differs, never that anyone changed it", () => {
    const html = render(
      place(
        publicRows([
          row({ current: { state: "value", value: "advise", line: 3 } }),
        ]),
      ),
    );
    expect(html).toContain(settingDiffers("enforce"));
    expect(html).toContain(SETTINGS_RESET);
  });

  it("offers no reset for a key already holding the package default", () => {
    const html = render(place(publicRows([row()])));
    expect(html).not.toContain(SETTINGS_RESET);
  });

  /// A key whose default is the empty string gets no placeholder from
  /// the default-as-placeholder rule, and a blank box states neither
  /// what the default is nor that empty is a real answer.
  it("states an empty package default rather than showing a blank box", () => {
    const container = mount(
      <SkillSettings
        skill="gh"
        settings={place(
          publicRows([row({ default: "", current: { state: "absent" } })]),
        )}
        edits={[]}
        secretEdits={[]}
        pickedFile={null}
        onEdit={() => {}}
        onSecretEdit={() => {}}
        onSecretEdits={() => {}}
        onPickFile={() => {}}
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
        settings={place(
          publicRows([
            row({
              current: {
                state: "ambiguous",
                problem: "it is assigned more than once",
                lines: [3, 9],
              },
            }),
          ]),
        )}
        edits={[]}
        secretEdits={[]}
        pickedFile={null}
        onEdit={() => {}}
        onSecretEdit={() => {}}
        onSecretEdits={() => {}}
        onPickFile={() => {}}
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

  /// A skill that declares nothing has nothing to show.
  it("shows no section for a template-less skill, empty rows, or an unread place", () => {
    const rows: [string, ScopeSettings | null][] = [
      ["no template", place({ state: "no-template" })],
      ["empty declared rows", place(publicRows([]))],
      ["unread place", null],
    ];
    expect(rows).toHaveLength(3);
    for (const [name, settings] of rows)
      expect(render(settings), name).toBe("");
  });

  /// A private file is a project's. A package installed for everything
  /// has none, and an empty section there would read as a package with
  /// nothing to configure rather than one configured somewhere else.
  it("sends a global place to a project rather than showing nothing", () => {
    const html = render({
      applies: false,
      skills: [],
      file: "kendex.settings.toml",
      base: null,
      secrets: null,
      contested: [],
    });
    expect(html).toContain(SECRETS_NEED_A_PROJECT);
  });

  /// The draft is what the save will write, so the row shows it in place
  /// of what the file currently holds.
  it("shows the unsaved answer over the one in the file", () => {
    const html = markup(
      <SkillSettings
        skill="gh"
        settings={place(publicRows([row()]))}
        edits={[
          {
            skill: "gh",
            key: "GH_MODE",
            value: { kind: "set", value: "advise" },
          },
        ]}
        secretEdits={[]}
        pickedFile={null}
        onEdit={() => {}}
        onSecretEdit={() => {}}
        onSecretEdits={() => {}}
        onPickFile={() => {}}
      />,
    );
    expect(html).toContain('value="advise"');
    expect(html).toContain(settingDiffers("enforce"));
  });

  /// Every edit names the skill whose template declares the key: core
  /// checks the edit against that declaration and refuses one written
  /// under somebody else's name.
  it("hands up a typed value bound to the skill that declares the key", async () => {
    const onEdit = vi.fn();
    const container = mount(
      <SkillSettings
        skill="gh"
        settings={place(publicRows([row()]))}
        edits={[]}
        secretEdits={[]}
        pickedFile={null}
        onEdit={onEdit}
        onSecretEdit={() => {}}
        onSecretEdits={() => {}}
        onPickFile={() => {}}
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
        settings={place(
          publicRows([
            row({ current: { state: "value", value: "advise", line: 3 } }),
          ]),
        )}
        edits={[]}
        secretEdits={[]}
        pickedFile={null}
        onEdit={onEdit}
        onSecretEdit={() => {}}
        onSecretEdits={() => {}}
        onPickFile={() => {}}
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

  /// The two kinds of key never share a section: they are written to
  /// different files under different rules, and a person about to type a
  /// credential has to read where it goes in the section they type into.
  it("puts credentials in their own section, naming the file they go to", () => {
    const html = render(
      place({
        state: "rows",
        rows: [row()],
        secrets: [
          {
            key: "GH_TOKEN",
            explainer: ["What the token lets it do."],
            required: true,
            current: { state: "not-set" },
          },
        ],
      }),
    );
    expect(html).toContain(SECRETS_SECTION);
    expect(html).toContain(secretsHelp(".env.local"));
    expect(html).toContain("GH_TOKEN");
    // And the public section is still its own, with its own help.
    expect(html).toContain(SETTINGS_HELP);
  });

  /// A section that says git does not carry the file, over a warning
  /// saying git tracks it, teaches a reader to trust neither. The
  /// destination's own state decides which sentence is true.
  it("claims nothing about git where the destination refuses", () => {
    const read = place({
      state: "rows",
      rows: [],
      secrets: [
        {
          key: "GH_TOKEN",
          explainer: ["What the token lets it do."],
          required: true,
          current: { state: "unknown", reason: "git already tracks it" },
        },
      ],
    });
    const html = render({
      ...read,
      secrets: {
        destination: {
          file: ".env.local",
          chosen: false,
          state: {
            state: "refused",
            problem: "git already tracks .env.local",
            fix: "run git rm --cached -- .env.local",
          },
        },
        candidates: [],
        base: null,
      },
    });
    expect(html).toContain(secretsHelpRefused(".env.local"));
    expect(html).not.toContain(secretsHelp(".env.local"));
    expect(html).not.toMatch(/git does not carry/);
  });

  /// A key whose template lists the values it takes is picked from, not
  /// typed into: a typo in a two-value setting is refused by the script
  /// that reads it, hours later and somewhere else. The list is the
  /// template's, in the template's order.
  ///
  /// jsdom lays nothing out, so nothing here asserts the picker's width
  /// or where it sits.
  it("picks a key that declares its values, and types every other key", async () => {
    const onEdit = vi.fn();
    const container = mounted(
      place(
        publicRows([
          row({
            values: ["enforce", "advise"],
            current: { state: "value", value: "advise", line: 3 },
          }),
          row({
            key: "GH_GLOB",
            default: "**/*.rs",
            current: { state: "absent" },
          }),
        ]),
      ),
      onEdit,
    );
    const triggers = container.querySelectorAll<HTMLElement>(
      '[data-slot="select-trigger"]',
    );
    expect(triggers).toHaveLength(1);
    expect(triggers[0].textContent).toContain("advise");
    // The key with no values line keeps the box a person types into, and
    // the picked key offers none. A picker carries a hidden input of its
    // own for form participation, which is not a box anybody reaches.
    expect(
      [...container.querySelectorAll("input:not([aria-hidden])")].map((one) =>
        one.getAttribute("aria-label"),
      ),
    ).toEqual(["GH_GLOB"]);

    const options = await opened(triggers[0]);
    expect(options.map((one) => one.textContent)).toEqual([
      "enforce",
      "advise",
    ]);
    await userEvent.click(options[0]);
    expect(onEdit).toHaveBeenLastCalledWith({
      skill: "gh",
      key: "GH_MODE",
      value: { kind: "set", value: "enforce" },
    });
  });

  /// The file's own answer stays on screen and stays in the file. A
  /// picker that dropped a value the template does not list would show a
  /// value the file does not hold; one that snapped to the default would
  /// rewrite somebody's answer the moment the page was read.
  it("shows a value outside the declared set as its own disabled option", async () => {
    const onEdit = vi.fn();
    const container = mounted(
      place(
        publicRows([
          row({
            values: ["enforce", "advise"],
            current: { state: "value", value: "Enforce", line: 3 },
          }),
        ]),
      ),
      onEdit,
    );
    const trigger = container.querySelector<HTMLElement>(
      '[data-slot="select-trigger"]',
    );
    if (!trigger) throw new Error("the row rendered no picker");
    expect(trigger.textContent).toContain("Enforce");

    const options = await opened(trigger);
    expect(options.map((one) => one.textContent)).toEqual([
      "Enforce",
      "enforce",
      "advise",
    ]);
    expect(options[0].dataset.disabled).toBeDefined();
    expect(onEdit).not.toHaveBeenCalled();
  });

  /// An empty value is a real answer for some keys, and a blank row is one
  /// nobody can tell from a rendering fault. The labels are written out
  /// here rather than read back from the copy the row uses, so a label
  /// that collides with another option's is a case this can fail on: core
  /// keeps a double quote out of every value the picker can hold, which is
  /// what makes a pair of them a label nothing else produces.
  it("labels an empty value so no other option reads the same", async () => {
    const rows: [string, SettingsRow, string[]][] = [
      [
        "an empty value among the declared ones",
        row({
          default: "",
          values: ["", "enforce"],
          current: { state: "absent" },
        }),
        ['""', "enforce"],
      ],
      [
        "an empty current value beside a declared literal empty",
        row({
          values: ["empty", "enforce"],
          current: { state: "value", value: "", line: 3 },
        }),
        ['""', "empty", "enforce"],
      ],
    ];
    expect(rows).toHaveLength(2);
    for (const [what, one, labels] of rows) {
      const container = mounted(place(publicRows([one])));
      const trigger = container.querySelector<HTMLElement>(
        '[data-slot="select-trigger"]',
      );
      if (!trigger) throw new Error(`${what}: the row rendered no picker`);
      const options = await opened(trigger);
      expect(
        options.map((option) => option.textContent),
        what,
      ).toEqual(labels);
    }
  });

  /// A key one package declares a setting and another a credential is
  /// offered by neither route, so the section says why rather than
  /// leaving a gap where a field used to be.
  it("explains a key two packages disagree about", () => {
    const read = place(publicRows([]));
    const html = render({
      ...read,
      contested: [
        {
          key: "SHARED",
          public: ["gh"],
          secret: ["linear"],
          problem:
            "gh declares SHARED as a setting and linear declares it as a secret",
        },
      ],
    });
    expect(html).toContain(CONTESTED_KEYS);
    expect(html).toContain("linear declares it as a secret");
  });
});
