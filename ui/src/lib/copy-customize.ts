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

// A package's credentials: the fields a person types a key into, where
// that key is kept, and what saving one is about to do.
export const SECRETS_SECTION = "Keys and tokens";
/** Never "keys": a person reading this is about to type one, and the
 *  sentence has to say where it goes before they do.
 *
 *  It says where a value goes and nothing about what wins. Which source a
 *  package prefers is that package's own policy and the packages differ:
 *  Linear gives a project key precedence over an inherited one, so that
 *  the key for one repository's workspace cannot be overridden by a
 *  machine-wide export, while Deep Research keeps the process value. One
 *  sentence here cannot be true of both, and the one that was here told a
 *  Linear user the wrong account's key would be used. Each package states
 *  its own rule in the comment block it ships beside the key, which is
 *  what the field's explainer shows. */
export const secretsHelp = (file: string): string =>
  `Saved in ${file}, which git does not carry and which the packages installed here read.`;
/** The same line for a destination nothing may be written to. It states
 *  where a value WOULD go and claims nothing about git, because the
 *  refusal below it often says git carries that very file — and a section
 *  that contradicts its own warning teaches a reader to trust neither. */
export const secretsHelpRefused = (file: string): string =>
  `This package's keys would go in ${file}. Nothing can be saved there yet.`;
export const SECRET_NOT_SET = "Not set";
export const SECRET_SET = "Set";
export const SECRET_UNKNOWN = "Can't check";
export const SECRET_REQUIRED = "Needed to run";
export const SECRET_SET_ACTION = "Set";
export const SECRET_REPLACE_ACTION = "Replace";
export const SECRET_CLEAR_ACTION = "Clear";
export const SECRET_CANCEL_ACTION = "Keep what's there";
export const SECRET_INPUT_PLACEHOLDER = "Paste the key";
export const SECRET_CLEARING = "Will be removed when you save.";
/** A stored value says somebody typed one, and nothing more. Saying
 *  "connected" here would claim kendex asked the provider, which it never
 *  does. */
export const SECRET_SET_NOTE =
  "A value is stored. kendex hasn't checked it with the provider.";
export const SECRET_HELP_LABEL = "What happens to this key";
/** The one explanation behind every field's info icon: what a secret is,
 *  where it goes, and what git does with it. Built from the destination
 *  the read resolved, never from a name typed here. */
export const secretFieldHelp = (file: string, writable = true): string =>
  writable
    ? `This is a secret. It is never written into your project's committed configuration — it is saved to ${file}, the private file this project keeps out of git.`
    : `This is a secret. It is never written into your project's committed configuration. It would go to ${file}, which can't be saved to yet.`;

// Where secrets go, and choosing somewhere else.
export const SECRET_FILE_LABEL = "Kept in";
export const SECRET_FILE_CHANGE = "Use another file";
export const SECRET_FILE_CANCEL = "Keep this one";
export const SECRET_FILE_DEFAULT_NOTE =
  "The file every project uses unless it names another.";
export const SECRET_FILE_RECORDED = (file: string): string =>
  `Saving records ${file} as this project's private file, so the packages read it too.`;
export const SECRET_FILE_WILL_CREATE = (file: string): string =>
  `${file} doesn't exist yet. Saving creates it, readable only by you.`;
export const SECRET_FILE_WILL_IGNORE = (entry: string, file: string): string =>
  `Saving also adds ${entry} to .gitignore first, so git never carries ${file}.`;
export const SECRET_FILE_REFUSED = "Nothing can be saved here yet";
export const SECRET_NO_CANDIDATES =
  "No other private env file in this project's folder.";
/** Project scope is where a private file lives. A package installed for
 *  everything has no project to keep one in, and a field here would imply
 *  a key was saved everywhere. */
export const SECRETS_NEED_A_PROJECT =
  "Settings and keys are set per project. Open this package in a project to see and set whatever it declares.";
/** Two packages saying different things about one key. Neither field is
 *  offered, so the line has to say why rather than leave a gap. */
export const CONTESTED_KEYS = "Two packages disagree about a key";

// What a save is about to write, before it writes it.
export const SAVE_CONFIRM_TITLE = "Save these changes";
export const SAVE_CONFIRM_DESCRIPTION = "Here's every file this writes to.";
export const SAVE_CONFIRM_ACTION = "Save and apply";
export const SAVE_CONFIRM_EMPTY = "Nothing to write.";
/** Secret fields are named and never shown. The dialog exists to say
 *  which file a value lands in; printing the value would put it on a
 *  screen a person opened to check where it was going. */
export const SAVE_CONFIRM_SECRET_NOTE =
  "Key values aren't shown here and aren't written anywhere else.";

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

// The customize surface's word for a value the person has set.
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
