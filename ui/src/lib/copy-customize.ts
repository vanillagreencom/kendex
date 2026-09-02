import type { HookDelivery } from "@/bindings";
import { EDITED_UPDATE_TAG, FORKED_BADGE_LABEL } from "@/lib/copy";
import type { ItemCustomization } from "@/lib/customization";
import type { CustomizedHere } from "@/lib/customized-places";
import type { GroupStatus } from "@/lib/derive";
import { harnessName } from "@/lib/labels";
import { listed } from "@/lib/listed";

// Product prose for customizing: the words on a package's Customize tab,
// on the Customize page, and the marks the Library draws for both. Same
// house style as copy.ts — split out for the file line cap.

// Per-harness settings. What a value here does, and the one case where it does
// nothing at all.
export const FRONTMATTER_HELP =
  "Your value wins over the catalog's. Leave a field blank to keep the catalog's.";
export const FRONTMATTER_IGNORED = (harness: string): string =>
  `${harness} doesn't read agent settings — anything saved here is kept, but has no effect.`;

// A package's own Customize tab.
export const CUSTOMIZE_TAB = "Customize";
export const OVERVIEW_TAB = "Overview";
export const WRITTEN_INTO =
  "Written into every harness's copy, alongside what the author wrote.";
export const LAUNCH_LABEL = "Launch instructions";
export const LAUNCH_HELP = "Added at the start of this agent's file.";
export const ADDITIONAL_LABEL = "Extra instructions";
export const ADDITIONAL_HELP = "Added at the end of this agent's file.";
export const SKILL_INSTRUCTIONS_LABEL = "Extra instructions";
export const SKILL_INSTRUCTIONS_HELP =
  "Added to this skill's own instructions — the author's text is never overwritten.";
export const SHARED_ALSO_APPLIES =
  "Your instructions for everything apply here too.";
export const SHARED_VIEW = "See them";
export const SKILLS_SECTION = "Skills";
// The automatic state has three answers, not two. A catalog that assigns
// nothing and a scope whose lock has not recorded an assignment yet are
// different facts, and printing the first over the second reads an agent
// nobody has asked about as an agent with no skills.
export const SKILLS_AUTOMATIC =
  "The catalog gives this agent these. Add one and this agent keeps exactly what you choose.";
export const SKILLS_AUTOMATIC_NONE =
  "The catalog gives this agent no skills. Add one and this agent keeps exactly what you choose.";
/** A reviewer agent with no row of its own renders its base agent's list.
 *  The chips are that row, so the line names where it lives — this page
 *  edits this agent's row, and picking here starts one. */
export const skillsInherited = (base: string): string =>
  `Set on ${base}, which this agent reads its skills from. Add one and this agent keeps exactly what you choose instead.`;
export const SKILLS_AUTOMATIC_UNRECORDED =
  "The catalog picks these, and kendex records which ones the next time it installs here. Add one and this agent keeps exactly what you choose.";
export const SKILLS_CHOSEN =
  "This agent gets exactly these. Remove them all to give it none.";
export const SKILLS_NONE_AVAILABLE =
  "No skills to add — your catalogs supply none yet.";
export const SKILLS_BACK_TO_AUTOMATIC = "Back to automatic";
export const SETTINGS_SECTION = "Settings";

// A skill's own settings: the keys its template declares, and where this
// project's file stands on each.
export const SETTINGS_HELP =
  "Saved in kendex.settings.toml in the project root. The process environment and .env.local are read first, so a value set in either wins over one set here.";
export const SETTINGS_RESET = "Reset to default";
/** The placeholder for a key whose package default is the empty string.
 *  A blank box states neither what the default is nor that empty is a
 *  real answer, and one phrase covers every such key — the explainer
 *  beside it already carries what empty means for that one. */
export const SETTINGS_DEFAULT_EMPTY = "empty by default";
/** How a settings value shows up in the Customize index — a statement
 *  about the file, never about who wrote it. */
const SETTINGS_VALUES_MARK = "Non-default settings";
export const SETTINGS_TEMPLATE_UNREADABLE =
  "This skill's settings can't be read here";
export const SETTINGS_TEMPLATE_INVALID =
  "This skill's settings template doesn't hold to the authoring contract";
/** Never "nothing is set": seeding is lenient, so keys from a template the
 *  strict reader refuses may well be in the file already. */
export const SETTINGS_TEMPLATE_INVALID_NOTE =
  "kendex can't list its keys, so they can't be edited here. Values from it may already be in kendex.settings.toml — open that file to see them.";

/** One thing wrong with a template, as its author has to fix it. */
export const templateFindingLine = (
  line: number,
  problem: string,
  fix: string,
): string =>
  line === 0 ? `${problem} — ${fix}` : `Line ${line}: ${problem} — ${fix}`;

/** A fact about the file, not about the reader: a value can differ from
 *  the default because it was seeded, imported, or written by hand, and
 *  nothing here knows who put it there. */
export const settingDiffers = (fallback: string): string =>
  fallback === ""
    ? "Differs from the package default, which is empty."
    : `Differs from the package default: ${fallback}`;

/** A key nothing here can write: the file answers for it in a shape no
 *  script reads, so the person settles it in the file. */
export const settingAmbiguous = (
  key: string,
  problem: string,
  lines: number[],
): string =>
  `${key} can't be set here — ${problem}: ${
    lines.length === 1 ? `line ${lines[0]}` : `lines ${lines.join(", ")}`
  }.`;

export const SAVE_NOTE =
  "Saving writes these changes into every harness that reads them.";
export const SAVE_FIRST = "Save your changes before switching location.";

// The Customize page: what belongs to everything rather than to one package.
export const CUSTOMIZE_SUBTITLE = "Your own edits on top of what you installed";
export const SHARED_SECTION = "Applies to everything";
export const SHARED_SECTION_HELP =
  "Written into every agent and skill here, on top of anything you set on a package of its own.";
export const SHARED_LAUNCH_HELP = "Added at the start of every agent's file.";
export const SHARED_ADDITIONAL_LABEL = "Extra instructions for agents";
export const SHARED_SKILL_LABEL = "Extra instructions for skills";
export const SHARED_ADDITIONAL_HELP = "Added at the end of every agent's file.";
export const SHARED_SKILL_HELP = "Added to every skill's instructions.";
export const HOOKS_SECTION = "Custom hooks";
export const PICK_EVENT = "Pick an event";
export const NO_EVENT_MATCHES = "No event matches that.";
export const MATCHER_HELP = "Matcher — the tool to watch (optional)";
export const HOOK_COMMAND_HELP =
  "Command — runs from the folder the session started in";
export const HOOK_COMMAND_PLACEHOLDER = "./scripts/guard.sh, or a full path";
export const HOOK_AGENTS_LABEL =
  "Agents — all, a role, or a comma-separated list";
export const HOOK_NAME_LABEL = "Name";
export const HOOK_NAME_PLACEHOLDER = "picked for you on save";
export const HOOK_TIMEOUT_LABEL = "Timeout — seconds it may run (optional)";
export const HOOK_HARNESSES_LABEL = "Where it installs";
export const HOOK_DISABLED_NOTE = "Switched off — kept here, nothing runs it.";
export const HOOKS_HELP =
  "Run where a harness can run them; written in as guidance where none can. Each hook says which below.";

/** The truth line under each hook, built from what the engine will actually
 *  do — never from prose in the UI. */
export function hookDeliverySummary(rows: HookDelivery[]): string {
  const named = (modes: HookDelivery["mode"][]) =>
    rows
      .filter((row) => modes.includes(row.mode))
      .map((row) => harnessName(row.harness));
  const runs = named(["runs", "runs-in-agent-file"]);
  const guidance = named(["instructions"]);
  const nowhere = named(["unavailable"]);
  const parts: string[] = [];
  if (runs.length > 0) parts.push(`Runs in ${listed(runs)}`);
  if (guidance.length > 0)
    parts.push(
      `guidance only in ${listed(guidance)} — nothing enforces it there`,
    );
  if (nowhere.length > 0) parts.push(`can't run in ${listed(nowhere)}`);
  if (parts.length === 0) return "";
  const line = parts.join(" · ");
  return line.charAt(0).toUpperCase() + line.slice(1);
}
export const CUSTOMIZED_SECTION = "Customized packages";
export const CUSTOMIZED_SECTION_HELP =
  "Each one is edited on its own page, where you can see what it ships with.";
export const NOTHING_CUSTOMIZED =
  "Nothing yet — open a package from the Library to customize it.";
export const NOT_INSTALLED_HERE = "Not installed here";
export const CUSTOMIZED_CHECKING = "Checking for hand edits and forks…";
export const CUSTOMIZED_UPDATES_UNCHECKED =
  "Hand-edited and forked packages may be missing: the check for updates failed. Try it again from Updates.";
export const REMOVE_CUSTOMIZATION = "Remove";

// What a package's row is marked with, in the Library's legend and on it.
export const AS_INSTALLED_MARK = "As the author wrote it";
export const CUSTOMIZED_MARK = "Customized by you";
export const STATUS_LABELS: Record<GroupStatus, string> = {
  active: "Active",
  off: "Switched off",
  broken: "Its link is broken",
};

/** What a person has set on one package, in a line — for the Customize
 *  index, where the point is to recognise your own edit and go to it. */
function customizationSummary(one: ItemCustomization): string {
  const parts: string[] = [];
  if (one.launch) parts.push(LAUNCH_LABEL);
  if (one.additional || one.instructions) parts.push(ADDITIONAL_LABEL);
  if (one.skills) {
    parts.push(
      one.skills.length === 1 ? "1 skill" : `${one.skills.length} skills`,
    );
  }
  for (const [harness] of one.frontmatter) {
    parts.push(`${harnessName(harness)} settings`);
  }
  return parts.join(" · ");
}

/** The line under an index row: how this place made the package its own.
 *  A fork and a hand edit are each named when they hold, then whatever
 *  settings sit on top; a settings-only row lists just those. */
export function customizedLine(
  facts: Pick<CustomizedHere, "edited" | "forked" | "values">,
  one: ItemCustomization,
): string {
  const parts: string[] = [];
  if (facts.forked) parts.push(FORKED_BADGE_LABEL);
  if (facts.edited) parts.push(EDITED_UPDATE_TAG);
  if (facts.values) parts.push(SETTINGS_VALUES_MARK);
  const settings = customizationSummary(one);
  if (settings) parts.push(settings);
  return parts.join(" · ");
}
