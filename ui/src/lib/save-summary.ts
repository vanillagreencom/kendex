import type { ScopeSettings, SecretEdit, SettingsEdit } from "@/bindings";
import { choosesFile } from "@/lib/secret-rows";

/** One file a save writes to, and what lands in it. */
export interface SaveGroup {
  file: string;
  /** Key names and section labels — never values. */
  labels: string[];
}

/**
 * What a save is about to write, grouped by the file it lands in.
 *
 * Every file name here comes from the read that produced the fields: the
 * manifest names its own file, because a source catalog keeps its install
 * state in a sibling of the definition it publishes, and the private file
 * is whichever one the destination resolved to. None of them is a name
 * this page holds, so the summary cannot say one file and the write go to
 * another.
 *
 * Labels are keys and section names. A secret's value is never here: this
 * dialog exists so a person can check where a credential is going, and
 * printing it on the way would be the opposite of that.
 */
export function saveGroups({
  manifestDirty,
  manifestFile,
  settingsEdits,
  secretEdits,
  pickedFile,
  settings,
}: {
  manifestDirty: boolean;
  /** What this place's manifest file is called, per its own read. */
  manifestFile: string | null;
  settingsEdits: SettingsEdit[];
  secretEdits: SecretEdit[];
  /** The private file the person picked on this page, null while they
   *  have not. Naming one the project does not already name is a write
   *  into the settings file, so it is a line in this summary. */
  pickedFile: string | null;
  settings: ScopeSettings | null;
}): SaveGroup[] {
  const groups: SaveGroup[] = [];
  if (manifestDirty && manifestFile) {
    add(groups, manifestFile, [CUSTOMIZATIONS_LABEL]);
  }
  if (settings) {
    add(
      groups,
      settings.file,
      settingsEdits.map((edit) => edit.key),
    );
    // The chosen file is recorded in the settings file, under the key
    // both package loaders read, so it belongs to that group rather than
    // to a line of its own.
    if (choosesFile(settings, pickedFile))
      add(groups, settings.file, [ENV_FILE_KEY]);
  }
  const destination = settings?.secrets?.destination;
  if (destination) {
    add(
      groups,
      destination.file,
      secretEdits.map((edit) => edit.key),
    );
  }
  return groups;
}

/** The label kendex writes for the manifest half, which is a set of edits
 *  rather than one named key. */
const CUSTOMIZATIONS_LABEL = "Your customizations";

/** The settings key that records this project's private file. Spelled
 *  here because the summary names it before the save writes it; core owns
 *  the write. */
const ENV_FILE_KEY = "KENDEX_ENV_FILE";

/** Add labels under their file, folding into the group already there.
 *  Two changes to one file are one line in this summary, and a change
 *  with no labels is not a change. */
function add(groups: SaveGroup[], file: string, labels: string[]): void {
  if (labels.length === 0) return;
  const held = groups.find((group) => group.file === file);
  if (held) held.labels.push(...labels);
  else groups.push({ file, labels: [...labels] });
}
