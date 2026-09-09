import type { ScopeSettings, SecretEdit, SettingsEdit } from "@/bindings";

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
  settings,
}: {
  manifestDirty: boolean;
  /** What this place's manifest file is called, per its own read. */
  manifestFile: string | null;
  settingsEdits: SettingsEdit[];
  secretEdits: SecretEdit[];
  settings: ScopeSettings | null;
}): SaveGroup[] {
  const groups: SaveGroup[] = [];
  if (manifestDirty && manifestFile) {
    groups.push({ file: manifestFile, labels: ["Your customizations"] });
  }
  if (settingsEdits.length > 0 && settings) {
    groups.push({
      file: settings.file,
      labels: settingsEdits.map((edit) => edit.key),
    });
  }
  const destination = settings?.secrets?.destination;
  if (secretEdits.length > 0 && destination) {
    groups.push({
      file: destination.file,
      labels: secretEdits.map((edit) => edit.key),
    });
  }
  return groups;
}
