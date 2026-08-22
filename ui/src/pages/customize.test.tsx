import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { emptyDraft } from "@/lib/editor-draft";
import { CustomizePage } from "./customize";

// Static markup serves each store's initial state, so what the page reads
// has to be handed to it rather than written into the store.
const editor = vi.hoisted(() => ({
  state: {} as Record<string, unknown>,
}));
const audit = vi.hoisted(() => ({ busy: false }));
const market = vi.hoisted(() => ({ busy: false }));
const settings = vi.hoisted(() => ({ busy: false, settings: null }));

vi.mock("@/stores/editor", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/editor")>();
  return {
    ...mod,
    useEditorStore: Object.assign(
      (selector?: (state: Record<string, unknown>) => unknown) =>
        selector ? selector(editor.state) : editor.state,
      { getState: () => editor.state, setState: () => {} },
    ),
  };
});
vi.mock("@/stores/marketplaces", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/marketplaces")>();
  return {
    ...mod,
    useMarketplacesStore: Object.assign(
      (selector?: (state: typeof market) => unknown) =>
        selector ? selector(market) : market,
      { getState: () => market },
    ),
  };
});
vi.mock("@/stores/settings", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/settings")>();
  return {
    ...mod,
    useSettingsStore: Object.assign(
      (selector?: (state: typeof settings) => unknown) =>
        selector ? selector(settings) : settings,
      { getState: () => settings },
    ),
  };
});
vi.mock("@/stores/audit", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/audit")>();
  return {
    ...mod,
    useAuditStore: Object.assign(
      (selector?: (state: typeof audit) => unknown) =>
        selector ? selector(audit) : audit,
      { getState: () => audit },
    ),
  };
});

/** The Save button's own tag, so a `disabled` elsewhere on the bar cannot
 *  stand in for this one. Matched as the rendered attribute: the class
 *  list carries `disabled:`-prefixed utilities either way. */
const saveButton = (html: string): string => {
  const label = html.indexOf("Save and apply");
  expect(label).toBeGreaterThan(-1);
  return html.slice(html.lastIndexOf("<button", label), label);
};

beforeEach(() => {
  audit.busy = false;
  market.busy = false;
  settings.busy = false;
  editor.state = {
    scope: { scope: "global" },
    draft: emptyDraft(),
    inventory: {
      declaredAgents: [],
      declaredSkills: [],
      availableSkills: [],
      harnesses: [],
      hookEvents: [],
    },
    held: {},
    dirty: true,
    loading: false,
    saving: false,
    error: null,
    setScope: () => {},
    load: () => {},
    discard: () => {},
    edit: () => {},
    save: () => {},
  };
});

// Apply, Adopt, Toggle and Remove all rewrite the same kendex.toml this
// page edits, and every one of them is started from another page. Someone
// who walks in here while one is still running must not be able to save a
// draft the file no longer matches.
describe("the Customize page's Save bar", () => {
  it("is live when nothing else is rewriting the file", () => {
    expect(saveButton(renderToStaticMarkup(<CustomizePage />))).not.toContain(
      'disabled=""',
    );
  });

  it("is held down while a mutation started elsewhere is in flight", () => {
    audit.busy = true;
    expect(saveButton(renderToStaticMarkup(<CustomizePage />))).toContain(
      'disabled=""',
    );
  });

  // An install or a subscription change rewrites the same file. It is a
  // writer like any other, and the gate names every writer or it names none.
  it("is held down while a marketplace write is in flight", () => {
    market.busy = true;
    expect(saveButton(renderToStaticMarkup(<CustomizePage />))).toContain(
      'disabled=""',
    );
  });

  // Adding the session drift report writes a project's settings file too.
  it("is held down while the drift report is being added", () => {
    settings.busy = true;
    expect(saveButton(renderToStaticMarkup(<CustomizePage />))).toContain(
      'disabled=""',
    );
  });
});
