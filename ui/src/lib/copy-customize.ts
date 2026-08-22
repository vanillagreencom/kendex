import type { HookDelivery } from "@/bindings";
import type { ItemCustomization } from "@/lib/customization";
import type { PlaceState } from "@/lib/customized-places";
import type { GroupStatus } from "@/lib/derive";
import { harnessName } from "@/lib/labels";

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
export const SKILLS_AUTOMATIC =
  "kendex picks these from the agent's tags. Add one and this agent keeps exactly what you choose.";
export const SKILLS_CHOSEN =
  "This agent gets exactly these. Remove them all to give it none.";
export const SKILLS_NONE_AVAILABLE =
  "No skills to add — your catalogs supply none yet.";
export const SKILLS_BACK_TO_AUTOMATIC = "Back to automatic";
export const SETTINGS_SECTION = "Settings";
export const SAVE_NOTE =
  "Saving writes these changes into every harness that reads them.";
// Typing parked at a place the editor moved away from. Moving between
// places keeps it rather than dropping it, and this is how anyone finds it
// again.
export const UNSAVED_ELSEWHERE_TITLE = "Unsaved changes at another location";
export const UNSAVED_ELSEWHERE_BODY =
  "They are kept exactly as you left them. Open the location to save or discard them.";
export const openLocationLabel = (place: string): string => `Open ${place}`;

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
  const list = (names: string[]) =>
    names.length === 2 ? names.join(" and ") : names.join(", ");
  const named = (modes: HookDelivery["mode"][]) =>
    rows
      .filter((row) => modes.includes(row.mode))
      .map((row) => harnessName(row.harness));
  const runs = named(["runs", "runs-in-agent-file"]);
  const guidance = named(["instructions"]);
  const nowhere = named(["unavailable"]);
  const parts: string[] = [];
  if (runs.length > 0) parts.push(`Runs in ${list(runs)}`);
  if (guidance.length > 0)
    parts.push(
      `guidance only in ${list(guidance)} — nothing enforces it there`,
    );
  if (nowhere.length > 0) parts.push(`can't run in ${list(nowhere)}`);
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
export const REMOVE_CUSTOMIZATION = "Remove";

// Every mark for a changed package names the place it is about, or counts
// the places it stands for: "Customized" on its own would say "somewhere",
// which is never the question being asked.
export const customizedInLabel = (place: string): string =>
  `Customized in ${place}`;
export const customizedPlacesLabel = (
  places: string[],
  total: number,
  unchecked: number,
): string => {
  // The first place named is the one clicking the mark opens, so where it
  // leads is on the label rather than found out on arrival; the count is
  // what the Where cell would otherwise have said.
  const said =
    total === 1 && places.length === 1
      ? customizedInLabel(places[0])
      : `${customizedInLabel(places[0])} · ${places.length} of ${total} places`;
  // A count of places implies the rest are untouched, so a place nothing
  // could be read for is said out loud rather than folded into the rest.
  return unchecked > 0 ? `${said} · ${unchecked} not checked` : said;
};
export const forkedInLabel = (places: string[]): string =>
  `Forked in ${places.join(", ")}`;
/** The fork mark where several places are listed at once, in the shape the
 *  customized mark beside it uses — the first place named because that is
 *  the one the mark opens, and a count for the rest so a row does not grow
 *  a list. */
export const forkedPlacesLabel = (
  places: string[],
  total: number,
  unchecked: number,
): string => {
  const said =
    total === 1 && places.length === 1
      ? forkedInLabel(places)
      : `${forkedInLabel([places[0]])} · ${places.length} of ${total} places`;
  // "1 of 3" says the other two are not forks, which is a claim about
  // places nobody could read. A place whose manifest would not load has no
  // answer either way, and folding it into the count invents one.
  return unchecked > 0 ? `${said} · ${unchecked} not checked` : said;
};
export const NOT_CHECKED_STATE = "not checked for your changes";
export const CHECKING_STATE = "still being checked";

/** One line of the per-place breakdown behind a mark: what is known about
 *  this place, including that nothing is. */
export const placeStateLine = (place: string, state: PlaceState): string => {
  const said: Record<PlaceState, string> = {
    customized: "customized by you",
    "as-installed": "as the author wrote it",
    checking: CHECKING_STATE,
    unknown: NOT_CHECKED_STATE,
  };
  return `${place} — ${said[state]}`;
};

// The marks rest on two reads: every place's manifest, and the update
// standing that carries hand edits. When one fails the table still lists
// every package, so it says which answer is missing — "no changes found"
// must never stand in for "we could not look".
export const MARKS_UNREAD_TITLE = "Your changes could not all be checked";
export const MARKS_UNREAD_UPDATES =
  "The update check has not run, so files you edited by hand are not counted yet.";
export const MARKS_UNREAD_MANIFESTS =
  "Some projects' settings could not be read, so their changes are not counted.";

// The key to the Library's icon colour. A muted icon means nothing of
// yours was found, which is not the same as having looked everywhere: a
// place kendex cannot read carries no mark either.
export const AS_INSTALLED_LEGEND = "No changes of yours found";
export const CUSTOMIZED_LEGEND = "Customized — the row names where";
export const STATUS_LABELS: Record<GroupStatus, string> = {
  active: "Active",
  off: "Switched off",
  broken: "Its link is broken",
};

/** What a person has set on one package, in a line — for the Customize
 *  index, where the point is to recognise your own edit and go to it. */
export function customizationSummary(one: ItemCustomization): string {
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
